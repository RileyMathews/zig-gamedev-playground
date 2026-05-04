// Zig standard library utilities. This program only uses it for the allocator.
const std = @import("std");

// zglfw creates the OS window and lets us poll for window/input events.
const zglfw = @import("zglfw");

// zgpu is the Zig wrapper around WebGPU/Dawn used for GPU rendering.
const zgpu = @import("zgpu");

pub fn main() !void {
    // Initialize GLFW before creating any windows.
    try zglfw.init();

    // Shut GLFW down when main exits, even if an error returns early.
    defer zglfw.terminate();

    // Tell GLFW not to create an OpenGL context. WebGPU owns the graphics API here.
    zglfw.windowHint(.client_api, .no_api);

    // Create the native OS window that WebGPU will render into.
    const window = try zglfw.Window.create(800, 600, "zig-gamedev playground", null, null);

    // Destroy the native window after the render loop exits.
    defer window.destroy();

    // zgpu needs an allocator for internal bookkeeping objects.
    const allocator = std.heap.page_allocator;

    // Create the WebGPU context. This owns the device, queue, surface, and swapchain.
    const gctx = try zgpu.GraphicsContext.create(
        allocator,
        .{
            // The window becomes the rendering target.
            .window = window,

            // zgpu calls these GLFW functions to query time, size, and native handles.
            // The platform-specific callbacks let the same code work on each OS.
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        },
        .{},
    );

    // Release all WebGPU resources owned by the context on exit.
    defer gctx.destroy(allocator);

    // Compile the WGSL shader source into a GPU shader module.
    const shader_module = zgpu.createWgslShaderModule(
        // The logical GPU device that creates GPU resources.
        gctx.device,
        // Embed the shader text into the executable at compile time.
        @embedFile("triangle.wgsl"),
        // Human-readable label used by graphics debuggers and validation messages.
        "triangle",
    );

    // The pipeline keeps its own reference, so the temporary shader module can be released later.
    defer shader_module.release();

    // A render pipeline is the fixed recipe for drawing: shader stages, primitive defaults,
    // output format, blending state, depth state, and related GPU configuration.
    const pipeline = gctx.device.createRenderPipeline(.{
        // Use vs_main from the shader module as the vertex stage.
        .vertex = .{ .module = shader_module, .entry_point = "vs_main" },

        // Use fs_main as the fragment stage that writes to the window's color texture.
        .fragment = &.{
            .module = shader_module,
            .entry_point = "fs_main",

            // This pipeline writes one color output: the swapchain texture.
            .target_count = 1,

            // The output format must match the textures produced by the swapchain.
            .targets = &.{.{ .format = zgpu.GraphicsContext.swapchain_format }},
        },
    });

    // Release the GPU pipeline when the program exits.
    defer pipeline.release();

    // Render frames until the user closes the window.
    while (!window.shouldClose()) {
        // Let GLFW process close, resize, keyboard, mouse, and other window events.
        zglfw.pollEvents();

        // Skip this frame if the swapchain is not currently drawable, such as while minimized.
        if (!gctx.canRender()) continue;

        // Get the current swapchain texture view. This is the image we will draw into.
        const back_buffer_view = gctx.swapchain.getCurrentTextureView();

        // Release this view after commands using it have been recorded.
        defer back_buffer_view.release();

        // Command encoders record GPU work. Nothing is submitted to the GPU yet.
        const encoder = gctx.device.createCommandEncoder(null);

        // Release the encoder object after it has produced a command buffer.
        defer encoder.release();

        // Begin a render pass targeting the window texture. The clear operation fills
        // the whole target with white before drawing the triangle.
        const pass = zgpu.beginRenderPassSimple(
            encoder,
            // Clear the target at the start of the pass instead of preserving old pixels.
            .clear,
            // Render into the current window back buffer.
            back_buffer_view,
            // RGBA clear color: white background, fully opaque.
            .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
            // No depth buffer is used for this 2D triangle.
            null,
            // No depth clear value because there is no depth buffer.
            null,
        );

        // Bind the triangle pipeline so following draw calls use its shaders/state.
        pass.setPipeline(pipeline);

        // Draw 3 vertices, 1 instance, starting at vertex 0 and instance 0.
        // The vertex shader turns those three vertex indices into triangle positions.
        pass.draw(3, 1, 0, 0);

        // End the render pass and release the pass encoder.
        zgpu.endReleasePass(pass);

        // Finish recording commands into an immutable command buffer.
        const commands = encoder.finish(null);

        // Release the command buffer object after submitting it.
        defer commands.release();

        // Submit the recorded command buffer to the GPU queue for execution.
        gctx.submit(&.{commands});

        // Present the finished swapchain image to the window.
        _ = gctx.present();
    }
}
