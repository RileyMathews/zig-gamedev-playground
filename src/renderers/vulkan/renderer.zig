const std = @import("std");

const vk = @import("vulkan");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const monogram_font = @import("monogram_font.zig");

const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;
const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;

// build.zig compiles the GLSL shaders to SPIR-V and exposes those binary blobs
// as anonymous imports. Vulkan consumes SPIR-V as 32-bit words, so keep the
// embedded bytes aligned like u32 data.
const rectangle_vert_spv align(@alignOf(u32)) = @embedFile("rectangle_vertex_shader").*;
const rectangle_frag_spv align(@alignOf(u32)) = @embedFile("rectangle_fragment_shader").*;
const text_vert_spv align(@alignOf(u32)) = @embedFile("text_vertex_shader").*;
const text_frag_spv align(@alignOf(u32)) = @embedFile("text_fragment_shader").*;

pub const Renderer = VulkanRenderer;

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const black: Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const white: Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
    pub const red: Color = .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const green: Color = .{ .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 };
    pub const blue: Color = .{ .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 };
    pub const brown: Color = .{ .r = 0.45, .g = 0.25, .b = 0.10, .a = 1.0 };
    pub const pink: Color = .{ .r = 1.0, .g = 0.20, .b = 0.70, .a = 1.0 };

    // Render pass clear colors use Vulkan's ClearValue union rather than the
    // renderer's public Color type.
    // TODO: Should we align public API to just use same types?
    fn toVkClear(self: Color) vk.ClearValue {
        return .{ .color = .{ .float_32 = .{
            self.r,
            self.g,
            self.b,
            self.a,
        } } };
    }
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub const FramebufferPixelSize = struct {
    width: u32,
    height: u32,
};

/// Position and size are framebuffer pixels, measured from the top-left.
pub const Rectangle = struct {
    position: Vec2,
    size: Vec2,

    pub fn centeredPosition(self: Rectangle, size: Vec2) Vec2 {
        return .{
            .x = self.position.x + (self.size.x - size.x) / 2.0,
            .y = self.position.y + (self.size.y - size.y) / 2.0,
        };
    }

    pub fn contains(self: Rectangle, position: Vec2) bool {
        return position.x >= self.position.x and
            position.x < self.position.x + self.size.x and
            position.y >= self.position.y and
            position.y < self.position.y + self.size.y;
    }
};

pub const DrawRectangle = struct {
    rectangle: Rectangle,
    color: Color = Color.black,
};

/// Position is framebuffer pixels, using raylib-style top-left text origin semantics.
pub const Text = struct {
    text: []const u8,
    position: Vec2,
    size: f32 = 24.0,
    color: Color = Color.black,
};

/// CPU-side text measurement using the same bitmap glyph advances that drawText
/// uses when it builds per-glyph GPU instances.
pub fn measureText(text: []const u8, size: f32) Vec2 {
    const view = std.unicode.Utf8View.init(text) catch return .{ .x = 0.0, .y = 0.0 };
    const scale_factor = size / monogram_font.base_size;
    const spacing = @trunc(scale_factor);

    var iterator = view.iterator();
    var max_width: f32 = 0.0;
    var line_width: f32 = 0.0;
    var height: f32 = if (text.len == 0) 0.0 else size;

    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') {
            max_width = @max(max_width, line_width);
            line_width = 0.0;
            height += size + text_line_spacing;
            continue;
        }

        const glyph = bitmapGlyph(codepoint) orelse bitmapGlyph('?').?;

        if (line_width > 0.0) {
            line_width += spacing;
        }
        line_width += glyph.width * scale_factor;
    }

    return .{
        .x = @max(max_width, line_width),
        .y = height,
    };
}

// Small per-frame values used by every vertex shader. Push constants are a
// Vulkan path for sending a few bytes directly with the command buffer, avoiding
// a separate uniform buffer allocation for data that changes every frame.
const FrameConstants = extern struct {
    framebuffer_size: [2]f32,
};

// Per-instance data is what changes for each drawn rectangle. The vertex shader
// reuses the same six generated quad vertices for every instance and reads these
// attributes to place/color each copy.
const RectangleInstance = extern struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
};

// Text is also drawn as instanced quads: one quad per visible glyph. uv_min and
// uv_max select the glyph's rectangle inside the font atlas texture.
const GlyphInstance = extern struct {
    position: [2]f32,
    size: [2]f32,
    uv_min: [2]f32,
    uv_max: [2]f32,
    color: [4]f32,
};

// A draw range points at a contiguous span of instance-buffer entries. This lets
// the renderer batch adjacent rectangles or glyphs into a single Vulkan draw.
const DrawRange = struct {
    start: usize,
    count: usize,
};

// The command stream preserves CPU draw order while still grouping consecutive
// draws of the same pipeline. That matters when rectangles and text overlap.
const DrawCommand = union(enum) {
    rectangles: DrawRange,
    text: DrawRange,
};

// Each rectangle or glyph is drawn as two triangles. The vertex shader generates
// the six corner positions from gl_VertexIndex, so no static quad vertex buffer
// is needed.
const quad_vertex_count = 6;
const max_rectangles_per_frame = 64 * 1024;
const max_text_glyphs_per_frame = 64 * 4096;
const max_draw_commands_per_frame = 64 * 1024;
const text_line_spacing: f32 = 2.0;

const app_name = "zig-gamedev playground";
// Rendering to a window requires the swapchain extension. The swapchain is the
// rotating set of images that Vulkan hands to us to draw into and then present.
const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

pub const VulkanRenderer = struct {
    allocator: std.mem.Allocator,
    window: *zglfw.Window,

    // Vulkan commands are loaded through dispatch tables. BaseWrapper knows how
    // to load global functions, while Instance and Device proxies load functions
    // whose availability depends on those handles.
    vkb: BaseWrapper,
    instance: Instance = undefined,
    dev: Device = undefined,
    has_instance: bool = false,
    has_device: bool = false,
    surface: vk.SurfaceKHR = .null_handle,
    pdev: vk.PhysicalDevice = .null_handle,
    mem_props: vk.PhysicalDeviceMemoryProperties = undefined,
    // Queue families are hardware/driver-defined groups of queues. Some queues
    // can run graphics commands; some can present images to the window surface.
    graphics_queue: Queue = .{},
    present_queue: Queue = .{},

    // A swapchain generation owns the window images and matching framebuffers
    // for one size/format. Resizing the window creates a new generation.
    swapchain: ?SwapchainGeneration = null,
    // The render pass describes how the swapchain image is used during a frame:
    // clear it at the start, draw color into it, and leave it ready to present.
    render_pass: vk.RenderPass = .null_handle,
    // This renderer records one primary command buffer per frame. The command
    // pool owns the memory backing command buffers for the graphics queue family.
    command_pool: vk.CommandPool = .null_handle,
    command_buffer: vk.CommandBuffer = .null_handle,

    // Semaphores order GPU work across queues; the fence lets the CPU wait until
    // the previous use of the single command buffer has finished.
    image_available: vk.Semaphore = .null_handle,
    render_finished: vk.Semaphore = .null_handle,
    in_flight_fence: vk.Fence = .null_handle,
    fatal_render_error: bool = false,

    // Pipelines bake shader programs plus fixed-function render state. Vulkan
    // makes this explicit so drawing can be cheap once setup is complete.
    pipeline_layout: vk.PipelineLayout = .null_handle,
    rectangle_pipeline: vk.Pipeline = .null_handle,
    // Text needs a sampled font texture, so it also needs descriptor objects.
    // Descriptors are Vulkan's way to bind resources that shaders can access.
    text_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    text_pipeline: vk.Pipeline = .null_handle,
    text_descriptor_pool: vk.DescriptorPool = .null_handle,
    text_descriptor_set: vk.DescriptorSet = .null_handle,

    // Instance buffers are persistently mapped CPU-visible memory. draw calls
    // write rectangle/glyph data directly into them before recording GPU draws.
    rectangle_instance_buffer: BufferResource = .{},
    text_instance_buffer: BufferResource = .{},
    bitmap_font_texture: FontTextureResources = .{},
    draw_commands: ?[]DrawCommand = null,

    debug_ui_initialized: bool = false,

    // A Frame represents one acquired swapchain image plus the command buffer
    // currently recording work for that image.
    pub const Frame = struct {
        renderer: *VulkanRenderer,
        image_index: u32,
        command_buffer: vk.CommandBuffer,
        rectangle_count: usize = 0,
        text_instance_count: usize = 0,
        draw_command_count: usize = 0,
        flushed_draw_command_count: usize = 0,
        ended: bool = false,

        // ImGui/zgui emits Vulkan commands directly into the frame's command
        // buffer. Flush queued game draws first so debug UI appears on top.
        pub fn beginDebugUi(self: *Frame, screen_width: u32, screen_height: u32) void {
            _ = self;
            zgui.backend.newFrame(screen_width, screen_height);
        }

        pub fn endDebugUi(self: *Frame) void {
            self.flushDraws();
            zgui.backend.render(imguiHandle(self.command_buffer));
        }

        // Public raylib-style call: append one rectangle to the mapped instance
        // buffer and queue a draw command that will be emitted later.
        pub fn drawRectangle(self: *Frame, rectangle: DrawRectangle) void {
            const renderer = self.renderer;
            if (self.rectangle_count >= max_rectangles_per_frame) return;
            if (!self.appendRectangleCommand(self.rectangle_count, 1)) return;

            const instance_buffer = &renderer.rectangle_instance_buffer;
            const mapped_instances: [*]RectangleInstance = @ptrCast(@alignCast(instance_buffer.mapped.?));
            mapped_instances[self.rectangle_count] = rectangleInstance(rectangle);
            self.rectangle_count += 1;
        }

        // Converts UTF-8 text into visible glyph instances. Spaces and tabs only
        // advance the cursor; they do not need quads because they draw nothing.
        pub fn drawText(self: *Frame, text: Text) void {
            const renderer = self.renderer;
            const view = std.unicode.Utf8View.init(text.text) catch return;
            const start_instance = self.text_instance_count;
            const instance_buffer = &renderer.text_instance_buffer;
            const mapped_instances: [*]GlyphInstance = @ptrCast(@alignCast(instance_buffer.mapped.?));
            const color = colorComponents(text.color);
            const scale_factor = text.size / monogram_font.base_size;
            const spacing = @trunc(scale_factor);

            var iterator = view.iterator();
            var text_offset_x: f32 = 0.0;
            var text_offset_y: f32 = 0.0;

            while (iterator.nextCodepoint()) |codepoint| {
                if (codepoint == '\n') {
                    text_offset_y += text.size + text_line_spacing;
                    text_offset_x = 0.0;
                    continue;
                }

                const glyph = bitmapGlyph(codepoint) orelse bitmapGlyph('?').?;

                if ((codepoint != ' ') and (codepoint != '\t')) {
                    if (self.text_instance_count >= max_text_glyphs_per_frame) break;
                    mapped_instances[self.text_instance_count] = glyphInstance(
                        .{
                            .x = text.position.x + text_offset_x,
                            .y = text.position.y + text_offset_y,
                        },
                        .{
                            .x = glyph.width * scale_factor,
                            .y = glyph.height * scale_factor,
                        },
                        glyph.atlas_bounds,
                        monogram_font.texture_width,
                        monogram_font.texture_height,
                        color,
                    );
                    self.text_instance_count += 1;
                }

                text_offset_x += glyph.width * scale_factor + spacing;
            }

            const instance_count = self.text_instance_count - start_instance;
            if (instance_count == 0) return;
            if (!self.appendTextCommand(start_instance, instance_count)) {
                self.text_instance_count = start_instance;
            }
        }

        // Finish recording the command buffer, submit it to the graphics queue,
        // then present the rendered swapchain image to the window.
        pub fn end(self: *Frame) void {
            if (self.ended) return;
            self.ended = true;

            const renderer = self.renderer;
            self.flushDraws();
            renderer.dev.cmdEndRenderPass(self.command_buffer);
            renderer.dev.endCommandBuffer(self.command_buffer) catch |err| {
                std.log.err("failed ending Vulkan command buffer: {s}", .{@errorName(err)});
                renderer.fatal_render_error = true;
                return;
            };

            const frame_fence = renderer.in_flight_fence;
            renderer.dev.resetFences(1, @ptrCast(&frame_fence)) catch |err| {
                std.log.err("failed resetting Vulkan frame fence: {s}", .{@errorName(err)});
                renderer.fatal_render_error = true;
                return;
            };

            // Wait until the acquired swapchain image is ready before the GPU
            // starts color output, then signal render_finished when drawing ends.
            const wait_stage = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
            const submit_info = vk.SubmitInfo{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = @ptrCast(&renderer.image_available),
                .p_wait_dst_stage_mask = &wait_stage,
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&self.command_buffer),
                .signal_semaphore_count = 1,
                .p_signal_semaphores = @ptrCast(&renderer.render_finished),
            };

            renderer.dev.queueSubmit(renderer.graphics_queue.handle, 1, @ptrCast(&submit_info), frame_fence) catch |err| {
                std.log.err("failed submitting Vulkan frame: {s}", .{@errorName(err)});
                renderer.fatal_render_error = true;
                return;
            };

            const swapchain = renderer.swapchain.?;
            // Present can report that the swapchain no longer matches the
            // window. That is normal after resize/minimize events.
            const present_result = renderer.dev.queuePresentKHR(renderer.present_queue.handle, &.{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = @ptrCast(&renderer.render_finished),
                .swapchain_count = 1,
                .p_swapchains = @ptrCast(&swapchain.handle),
                .p_image_indices = @ptrCast(&self.image_index),
            }) catch |err| switch (err) {
                error.OutOfDateKHR => vk.Result.error_out_of_date_khr,
                else => {
                    std.log.err("failed presenting Vulkan frame: {s}", .{@errorName(err)});
                    renderer.fatal_render_error = true;
                    return;
                },
            };

            if (present_result == .suboptimal_khr or present_result == .error_out_of_date_khr) {
                renderer.recreateSwapchain() catch |err| {
                    std.log.err("failed recreating Vulkan swapchain after present: {s}", .{@errorName(err)});
                };
            }
        }

        fn flushDraws(self: *Frame) void {
            const renderer = self.renderer;
            const commands = renderer.draw_commands.?;

            // Commands can be flushed before the frame ends, for example before
            // rendering debug UI. Keep the cursor so later flushes only emit new
            // commands.
            while (self.flushed_draw_command_count < self.draw_command_count) {
                const command = commands[self.flushed_draw_command_count];
                switch (command) {
                    .rectangles => |range| self.flushRectangles(range),
                    .text => |range| self.flushText(range),
                }
                self.flushed_draw_command_count += 1;
            }
        }

        fn appendRectangleCommand(self: *Frame, start: usize, count: usize) bool {
            const renderer = self.renderer;
            const commands = renderer.draw_commands.?;

            // Consecutive rectangle calls can share one pipeline bind and one
            // instanced draw, so extend the previous range when possible.
            if (self.draw_command_count > self.flushed_draw_command_count) {
                const last = &commands[self.draw_command_count - 1];
                switch (last.*) {
                    .rectangles => |*range| {
                        if (range.start + range.count == start) {
                            range.count += count;
                            return true;
                        }
                    },
                    .text => {},
                }
            }

            if (self.draw_command_count >= commands.len) return false;
            commands[self.draw_command_count] = .{ .rectangles = .{ .start = start, .count = count } };
            self.draw_command_count += 1;
            return true;
        }

        fn appendTextCommand(self: *Frame, start: usize, count: usize) bool {
            const renderer = self.renderer;
            const commands = renderer.draw_commands.?;

            // Text can also batch, but only while no other draw type has been
            // inserted between glyph ranges. That preserves visual ordering.
            if (self.draw_command_count > self.flushed_draw_command_count) {
                const last = &commands[self.draw_command_count - 1];
                switch (last.*) {
                    .text => |*range| {
                        if (range.start + range.count == start) {
                            range.count += count;
                            return true;
                        }
                    },
                    .rectangles => {},
                }
            }

            if (self.draw_command_count >= commands.len) return false;
            commands[self.draw_command_count] = .{ .text = .{ .start = start, .count = count } };
            self.draw_command_count += 1;
            return true;
        }

        fn flushRectangles(self: *Frame, range: DrawRange) void {
            const renderer = self.renderer;
            if (range.count == 0) return;

            const byte_offset = range.start * @sizeOf(RectangleInstance);
            const instance_buffer = &renderer.rectangle_instance_buffer;
            const offset = [_]vk.DeviceSize{@intCast(byte_offset)};

            // Bind the rectangle pipeline and the slice of instance data for
            // this range. cmdDraw's instance count tells the GPU how many quads
            // to generate from the same six vertices.
            renderer.dev.cmdBindPipeline(self.command_buffer, .graphics, renderer.rectangle_pipeline);
            renderer.dev.cmdBindVertexBuffers(self.command_buffer, 0, 1, @ptrCast(&instance_buffer.buffer), &offset);
            renderer.dev.cmdDraw(self.command_buffer, quad_vertex_count, @intCast(range.count), 0, 0);
        }

        fn flushText(self: *Frame, range: DrawRange) void {
            const renderer = self.renderer;
            if (range.count == 0) return;

            const byte_offset = range.start * @sizeOf(GlyphInstance);

            // Text uses a different pipeline because the fragment shader samples
            // the font atlas. Bind the descriptor set so that shader can see the
            // atlas image and sampler.
            renderer.dev.cmdBindPipeline(self.command_buffer, .graphics, renderer.text_pipeline);
            renderer.dev.cmdBindDescriptorSets(
                self.command_buffer,
                .graphics,
                renderer.pipeline_layout,
                0,
                1,
                @ptrCast(&renderer.text_descriptor_set),
                0,
                null,
            );
            const offset = [_]vk.DeviceSize{@intCast(byte_offset)};
            const instance_buffer = &renderer.text_instance_buffer;
            renderer.dev.cmdBindVertexBuffers(self.command_buffer, 0, 1, @ptrCast(&instance_buffer.buffer), &offset);
            renderer.dev.cmdDraw(self.command_buffer, quad_vertex_count, @intCast(range.count), 0, 0);
        }
    };

    /// Creates the Vulkan objects needed to draw rectangles and bitmap text into
    /// the GLFW window. The setup order follows Vulkan's dependency chain:
    /// instance -> surface/device -> swapchain/render pass -> pipelines/resources.
    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !VulkanRenderer {
        if (!zglfw.isVulkanSupported()) return error.VulkanUnavailable;

        var self = VulkanRenderer{
            .allocator = allocator,
            .window = window,
            .vkb = BaseWrapper.load(getGlfwInstanceProcAddr),
        };
        errdefer self.deinit();

        // The Vulkan instance is the process-level connection to the loader and
        // extensions needed by GLFW to create a window surface.
        const instance_handle = try createInstance(&self.vkb);
        const vki = try allocator.create(InstanceWrapper);
        vki.* = InstanceWrapper.load(instance_handle, self.vkb.dispatch.vkGetInstanceProcAddr.?);
        self.instance = Instance.init(instance_handle, vki);
        self.has_instance = true;

        try zglfw.createWindowSurface(self.instance.handle, window, null, &self.surface);

        // A physical device is the actual GPU/driver. The logical device is the
        // application's connection to that GPU, including the queues we will use.
        const candidate = try pickPhysicalDevice(self.instance, allocator, self.surface);
        self.pdev = candidate.pdev;

        const device_handle = try initializeDevice(self.instance, candidate);
        const vkd = try allocator.create(DeviceWrapper);
        vkd.* = DeviceWrapper.load(device_handle, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        self.dev = Device.init(device_handle, vkd);
        self.has_device = true;

        self.graphics_queue = Queue.init(self.dev, candidate.queues.graphics_family);
        self.present_queue = Queue.init(self.dev, candidate.queues.present_family);
        self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

        // Render pass and swapchain must agree on the image format that the
        // window system will present.
        const surface_format = try findSurfaceFormat(&self, allocator, null);
        self.render_pass = try self.createRenderPass(surface_format.format);
        self.command_pool = try self.dev.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.graphics_queue.family,
        }, null);
        try self.dev.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&self.command_buffer));

        self.swapchain = try SwapchainGeneration.create(&self, .null_handle, surface_format);
        try self.createSyncObjects();

        // Pipelines bake the shader interface, render state, and render pass
        // compatibility. Descriptor layout comes first because the text pipeline
        // layout must advertise the font texture binding.
        self.text_descriptor_set_layout = try self.createTextDescriptorSetLayout();
        self.pipeline_layout = try self.createPipelineLayout();
        self.rectangle_pipeline = try self.createRectanglePipeline();
        self.text_pipeline = try self.createTextPipeline();
        self.text_descriptor_pool = try self.createTextDescriptorPool();

        // These buffers stay mapped for the life of the renderer because the CPU
        // rewrites transient draw data every frame.
        self.rectangle_instance_buffer = try self.createBuffer(
            @sizeOf(RectangleInstance) * max_rectangles_per_frame,
            .{ .vertex_buffer_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
            true,
        );
        self.text_instance_buffer = try self.createBuffer(
            @sizeOf(GlyphInstance) * max_text_glyphs_per_frame,
            .{ .vertex_buffer_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
            true,
        );
        self.draw_commands = try allocator.alloc(DrawCommand, max_draw_commands_per_frame);
        self.bitmap_font_texture = try self.createBitmapFontTextureResources();
        // Descriptor sets contain the concrete resource handles matching the
        // descriptor set layout, in this case the font image view plus sampler.
        self.text_descriptor_set = try self.createTextDescriptorSet();

        return self;
    }

    /// Releases Vulkan resources in roughly the opposite order from creation.
    /// GPU work must be idle before destroying objects that queued commands may
    /// still reference.
    pub fn deinit(self: *VulkanRenderer) void {
        if (self.has_device) {
            self.dev.deviceWaitIdle() catch {};
        }
        self.deinitDebugUi();

        self.bitmap_font_texture.deinit(self);
        self.text_instance_buffer.deinit(self);
        self.rectangle_instance_buffer.deinit(self);
        if (self.draw_commands) |draw_commands| {
            self.allocator.free(draw_commands);
            self.draw_commands = null;
        }

        if (self.text_descriptor_pool != .null_handle) self.dev.destroyDescriptorPool(self.text_descriptor_pool, null);
        if (self.text_pipeline != .null_handle) self.dev.destroyPipeline(self.text_pipeline, null);
        if (self.rectangle_pipeline != .null_handle) self.dev.destroyPipeline(self.rectangle_pipeline, null);
        if (self.pipeline_layout != .null_handle) self.dev.destroyPipelineLayout(self.pipeline_layout, null);
        if (self.text_descriptor_set_layout != .null_handle) self.dev.destroyDescriptorSetLayout(self.text_descriptor_set_layout, null);

        self.destroySyncObjects();
        if (self.swapchain) |*swapchain| {
            swapchain.deinit(self);
            self.swapchain = null;
        }
        if (self.command_pool != .null_handle) self.dev.destroyCommandPool(self.command_pool, null);
        if (self.render_pass != .null_handle) self.dev.destroyRenderPass(self.render_pass, null);

        if (self.has_device) {
            self.dev.destroyDevice(null);
            self.allocator.destroy(self.dev.wrapper);
        }
        if (self.surface != .null_handle and self.has_instance) self.instance.destroySurfaceKHR(self.surface, null);
        if (self.has_instance) {
            self.instance.destroyInstance(null);
            self.allocator.destroy(self.instance.wrapper);
        }
    }

    /// Current drawable size in physical framebuffer pixels, not logical window
    /// coordinates. High-DPI displays can make these differ.
    pub fn framebufferPixelSize(self: *VulkanRenderer) FramebufferPixelSize {
        const swapchain = self.swapchain.?;
        return .{
            .width = swapchain.extent.width,
            .height = swapchain.extent.height,
        };
    }

    /// Initializes the zgui Vulkan backend so ImGui can append its own draw
    /// commands into our render pass.
    pub fn initDebugUi(self: *VulkanRenderer, window: *zglfw.Window) !void {
        const swapchain = self.swapchain.?;
        if (!zgui.backend.loadFunctions(versionToU32(vk.API_VERSION_1_3), loadZguiVulkanFunction, self)) {
            return error.DebugUiVulkanLoadFailed;
        }

        zgui.backend.init(.{
            .api_version = versionToU32(vk.API_VERSION_1_3),
            .instance = imguiHandle(self.instance.handle),
            .physical_device = imguiHandle(self.pdev),
            .device = imguiHandle(self.dev.handle),
            .queue_family = self.graphics_queue.family,
            .queue = imguiHandle(self.graphics_queue.handle),
            .descriptor_pool = null,
            .render_pass = imguiHandle(self.render_pass),
            .min_image_count = swapchain.min_image_count,
            .image_count = @intCast(swapchain.image_views.len),
            .msaa_samples = (vk.SampleCountFlags{ .@"1_bit" = true }).toInt(),
            .descriptor_pool_size = 64,
        }, window);
        self.debug_ui_initialized = true;
    }

    pub fn deinitDebugUi(self: *VulkanRenderer) void {
        if (!self.debug_ui_initialized) return;
        if (self.has_device) self.dev.deviceWaitIdle() catch {};
        zgui.backend.deinit();
        self.debug_ui_initialized = false;
    }

    /// Starts rendering a frame. Returns null when rendering should be skipped,
    /// for example while the window is minimized or after an unrecoverable Vulkan
    /// error.
    pub fn beginFrame(self: *VulkanRenderer, clear_color: Color) ?Frame {
        if (self.fatal_render_error) return null;

        // A minimized window can report a zero-size framebuffer. Vulkan cannot
        // create or render to zero-size swapchain images.
        const requested_extent = self.windowFramebufferExtent();
        if (requested_extent.width == 0 or requested_extent.height == 0) return null;

        var swapchain = self.swapchain.?;

        // The swapchain images are fixed-size; recreate them when the window's
        // framebuffer size changes.
        if (requested_extent.width != swapchain.extent.width or requested_extent.height != swapchain.extent.height) {
            self.recreateSwapchain() catch |err| {
                std.log.err("failed to recreate Vulkan swapchain: {s}", .{@errorName(err)});
                return null;
            };
            swapchain = self.swapchain.?;
        }

        // This renderer keeps one command buffer and one set of frame sync
        // objects, so wait until the previous submission has fully finished.
        const frame_fence = self.in_flight_fence;
        _ = self.dev.waitForFences(1, @ptrCast(&frame_fence), .true, std.math.maxInt(u64)) catch |err| {
            std.log.err("failed waiting for Vulkan frame fence: {s}", .{@errorName(err)});
            self.fatal_render_error = true;
            return null;
        };

        // Acquire chooses the next swapchain image we are allowed to render into.
        // image_available will be signaled by the presentation engine when that
        // image is actually ready for GPU drawing.
        const acquired = self.dev.acquireNextImageKHR(
            swapchain.handle,
            std.math.maxInt(u64),
            self.image_available,
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.recreateSwapchain() catch |recreate_err| {
                    std.log.err("failed to recreate out-of-date Vulkan swapchain: {s}", .{@errorName(recreate_err)});
                };
                return null;
            },
            else => {
                std.log.err("failed to acquire Vulkan swapchain image: {s}", .{@errorName(err)});
                self.fatal_render_error = true;
                return null;
            },
        };

        const image_index = acquired.image_index;
        const command_buffer = self.command_buffer;
        // Command buffers are just recorded command lists; reset and rerecord the
        // list each frame with the current target image and draw commands.
        self.dev.resetCommandBuffer(command_buffer, .{}) catch |err| {
            std.log.err("failed resetting Vulkan command buffer: {s}", .{@errorName(err)});
            self.fatal_render_error = true;
            return null;
        };
        self.dev.beginCommandBuffer(command_buffer, &.{}) catch |err| {
            std.log.err("failed beginning Vulkan command buffer: {s}", .{@errorName(err)});
            self.fatal_render_error = true;
            return null;
        };

        const render_area = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swapchain.extent,
        };
        const clear = clear_color.toVkClear();
        // Beginning the render pass selects the framebuffer for this swapchain
        // image and performs the configured clear operation.
        self.dev.cmdBeginRenderPass(command_buffer, &.{
            .render_pass = self.render_pass,
            .framebuffer = swapchain.framebuffers[image_index],
            .render_area = render_area,
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear),
        }, .@"inline");

        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(swapchain.extent.width),
            .height = @floatFromInt(swapchain.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = swapchain.extent,
        };
        // These are dynamic pipeline states, so they can be set per frame rather
        // than baked into every pipeline object.
        self.dev.cmdSetViewport(command_buffer, 0, 1, @ptrCast(&viewport));
        self.dev.cmdSetScissor(command_buffer, 0, 1, @ptrCast(&scissor));

        const frame_constants = FrameConstants{ .framebuffer_size = .{
            @floatFromInt(swapchain.extent.width),
            @floatFromInt(swapchain.extent.height),
        } };
        // Shaders use the framebuffer size to convert the public top-left pixel
        // coordinate API into Vulkan clip-space coordinates.
        self.dev.cmdPushConstants(
            command_buffer,
            self.pipeline_layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(FrameConstants),
            @ptrCast(&frame_constants),
        );

        return .{
            .renderer = self,
            .image_index = image_index,
            .command_buffer = command_buffer,
        };
    }

    fn createBuffer(
        self: *VulkanRenderer,
        size: vk.DeviceSize,
        usage: vk.BufferUsageFlags,
        memory_flags: vk.MemoryPropertyFlags,
        map_memory: bool,
    ) !BufferResource {
        // Vulkan separates buffer handles from the memory backing them. First
        // create the buffer object, then ask the driver what memory requirements
        // that object has and bind a matching allocation.
        const buffer = try self.dev.createBuffer(&.{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        }, null);
        errdefer self.dev.destroyBuffer(buffer, null);

        const requirements = self.dev.getBufferMemoryRequirements(buffer);
        const memory = try self.allocate(requirements, memory_flags);
        errdefer self.dev.freeMemory(memory, null);

        try self.dev.bindBufferMemory(buffer, memory, 0);
        const mapped = if (map_memory) try self.dev.mapMemory(memory, 0, size, .{}) else null;

        return .{
            .buffer = buffer,
            .memory = memory,
            .mapped = mapped,
            .size = size,
        };
    }

    fn allocate(self: *const VulkanRenderer, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
        // memory_type_bits is a bitset of memory heaps compatible with the
        // resource. findMemoryTypeIndex narrows that to one with the requested
        // properties, such as CPU-visible or device-local memory.
        return try self.dev.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
        }, null);
    }

    fn findMemoryTypeIndex(self: *const VulkanRenderer, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |memory_type, i| {
            if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and memory_type.property_flags.contains(flags)) {
                return @truncate(i);
            }
        }
        return error.NoSuitableMemoryType;
    }

    fn recreateSwapchain(self: *VulkanRenderer) !void {
        const requested_extent = self.windowFramebufferExtent();
        if (requested_extent.width == 0 or requested_extent.height == 0) return error.InvalidSurfaceDimensions;

        // Waiting idle is simple and safe for this POC. A more advanced renderer
        // would keep old swapchains alive until only the work using them finishes.
        try self.dev.deviceWaitIdle();

        var old_generation = self.swapchain.?;
        const new_generation = try SwapchainGeneration.create(self, old_generation.handle, old_generation.surface_format);
        self.swapchain = new_generation;
        old_generation.deinit(self);

        if (self.debug_ui_initialized) {
            zgui.backend.set_min_image_count(new_generation.min_image_count);
        }
    }

    fn createSyncObjects(self: *VulkanRenderer) !void {
        self.image_available = try self.dev.createSemaphore(&.{}, null);
        self.render_finished = try self.dev.createSemaphore(&.{}, null);
        // Start signaled so the first frame does not wait forever for a previous
        // submission that does not exist yet.
        self.in_flight_fence = try self.dev.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
    }

    fn destroySyncObjects(self: *VulkanRenderer) void {
        if (self.image_available != .null_handle) self.dev.destroySemaphore(self.image_available, null);
        if (self.render_finished != .null_handle) self.dev.destroySemaphore(self.render_finished, null);
        if (self.in_flight_fence != .null_handle) self.dev.destroyFence(self.in_flight_fence, null);
    }

    fn createRenderPass(self: *VulkanRenderer, format: vk.Format) !vk.RenderPass {
        // A render pass describes attachments and their lifetime inside a frame.
        // This pass has one color attachment: clear it, draw into it, then leave
        // it in the layout required by presentation.
        const color_attachment = vk.AttachmentDescription{
            .flags = .{},
            .format = format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        };

        const color_attachment_ref = vk.AttachmentReference{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        };

        // A subpass is a phase inside a render pass. We only need one graphics
        // subpass that writes to the swapchain color attachment.
        const subpass = vk.SubpassDescription{
            .flags = .{},
            .pipeline_bind_point = .graphics,
            .input_attachment_count = 0,
            .p_input_attachments = undefined,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment_ref),
            .p_resolve_attachments = null,
            .p_depth_stencil_attachment = null,
            .preserve_attachment_count = 0,
            .p_preserve_attachments = undefined,
        };

        return try self.dev.createRenderPass(&.{
            .flags = .{},
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_attachment),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 0,
            .p_dependencies = undefined,
        }, null);
    }

    fn framePushConstantRange() vk.PushConstantRange {
        // The pipeline layout must declare which shader stages may read each
        // push-constant byte range before command buffers can write it.
        return .{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(FrameConstants),
        };
    }

    fn createRectanglePipeline(self: *VulkanRenderer) !vk.Pipeline {
        // input_rate = instance means these attributes advance once per rectangle
        // rather than once per generated vertex.
        const binding = vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(RectangleInstance),
            .input_rate = .instance,
        };
        const attributes = [_]vk.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(RectangleInstance, "position") },
            .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(RectangleInstance, "size") },
            .{ .location = 2, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(RectangleInstance, "color") },
        };

        return try self.createGraphicsPipeline(
            rectangle_vert_spv[0..],
            rectangle_frag_spv[0..],
            self.pipeline_layout,
            binding,
            attributes[0..],
            false,
        );
    }

    fn createTextDescriptorSetLayout(self: *VulkanRenderer) !vk.DescriptorSetLayout {
        // Binding 0 is the font atlas plus sampler used by text.frag. The layout
        // describes the type and shader visibility, not the actual image.
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };

        return try self.dev.createDescriptorSetLayout(&.{
            .flags = .{},
            .binding_count = 1,
            .p_bindings = @ptrCast(&binding),
        }, null);
    }

    fn createPipelineLayout(self: *VulkanRenderer) !vk.PipelineLayout {
        const frame_constants_range = framePushConstantRange();
        // The layout is shared by both pipelines. Rectangles do not read the text
        // descriptor set, but sharing one layout keeps binding code simple.
        return try self.dev.createPipelineLayout(&.{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.text_descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&frame_constants_range),
        }, null);
    }

    fn createTextPipeline(self: *VulkanRenderer) !vk.Pipeline {
        // Text instances carry both screen placement and UV bounds into the font
        // atlas. The fragment shader uses the sampled alpha as the glyph mask.
        const binding = vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(GlyphInstance),
            .input_rate = .instance,
        };
        const attributes = [_]vk.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(GlyphInstance, "position") },
            .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(GlyphInstance, "size") },
            .{ .location = 2, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(GlyphInstance, "uv_min") },
            .{ .location = 3, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(GlyphInstance, "uv_max") },
            .{ .location = 4, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(GlyphInstance, "color") },
        };

        return try self.createGraphicsPipeline(
            text_vert_spv[0..],
            text_frag_spv[0..],
            self.pipeline_layout,
            binding,
            attributes[0..],
            true,
        );
    }

    fn createGraphicsPipeline(
        self: *VulkanRenderer,
        vert_spv: []align(@alignOf(u32)) const u8,
        frag_spv: []align(@alignOf(u32)) const u8,
        layout: vk.PipelineLayout,
        binding: vk.VertexInputBindingDescription,
        attributes: []const vk.VertexInputAttributeDescription,
        alpha_blend: bool,
    ) !vk.Pipeline {
        // Shader modules are temporary wrappers around SPIR-V bytecode. Once the
        // pipeline is created, Vulkan has copied what it needs from them.
        const vert = try self.dev.createShaderModule(&.{
            .flags = .{},
            .code_size = vert_spv.len,
            .p_code = @ptrCast(vert_spv.ptr),
        }, null);
        defer self.dev.destroyShaderModule(vert, null);

        const frag = try self.dev.createShaderModule(&.{
            .flags = .{},
            .code_size = frag_spv.len,
            .p_code = @ptrCast(frag_spv.ptr),
        }, null);
        defer self.dev.destroyShaderModule(frag, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .flags = .{},
                .stage = .{ .vertex_bit = true },
                .module = vert,
                .p_name = "main",
                .p_specialization_info = null,
            },
            .{
                .flags = .{},
                .stage = .{ .fragment_bit = true },
                .module = frag,
                .p_name = "main",
                .p_specialization_info = null,
            },
        };
        // Vertex input tells Vulkan how bytes in the bound instance buffer map to
        // shader input locations like in_position or in_color.
        const vertex_input = vk.PipelineVertexInputStateCreateInfo{
            .flags = .{},
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&binding),
            .vertex_attribute_description_count = @intCast(attributes.len),
            .p_vertex_attribute_descriptions = attributes.ptr,
        };
        // Every quad is submitted as a triangle list: vertices 0,1,2 form the
        // first triangle and vertices 3,4,5 form the second.
        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .flags = .{},
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        };
        // The actual viewport/scissor rectangles are dynamic state, so these
        // pointers are intentionally filled when recording a frame, not here.
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .flags = .{},
            .viewport_count = 1,
            .p_viewports = undefined,
            .scissor_count = 1,
            .p_scissors = undefined,
        };
        // Rasterization turns triangles into fragments/pixels. Culling is off so
        // our generated triangle winding does not accidentally hide 2D quads.
        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .flags = .{},
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };
        // No multisampling for now; each covered pixel gets one sample.
        const multisample = vk.PipelineMultisampleStateCreateInfo{
            .flags = .{},
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };
        // Text needs alpha blending so glyph edges/holes let the background show
        // through. Solid rectangles write their color directly.
        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blend_enable = if (alpha_blend) .true else .false,
            .src_color_blend_factor = if (alpha_blend) .src_alpha else .one,
            .dst_color_blend_factor = if (alpha_blend) .one_minus_src_alpha else .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = if (alpha_blend) .one else .one,
            .dst_alpha_blend_factor = if (alpha_blend) .one_minus_src_alpha else .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };
        const color_blend = vk.PipelineColorBlendStateCreateInfo{
            .flags = .{},
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_blend_attachment),
            .blend_constants = [_]f32{ 0, 0, 0, 0 },
        };
        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        // Dynamic state keeps window-size dependent values out of pipeline
        // objects, avoiding pipeline recreation on resize.
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .flags = .{},
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };
        const pipeline_info = vk.GraphicsPipelineCreateInfo{
            .flags = .{},
            .stage_count = shader_stages.len,
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &input_assembly,
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisample,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blend,
            .p_dynamic_state = &dynamic_state,
            .layout = layout,
            .render_pass = self.render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        var pipeline: vk.Pipeline = undefined;
        // A graphics pipeline is the full recipe for drawing: shader stages,
        // vertex data layout, fixed-function state, and render-pass compatibility.
        _ = try self.dev.createGraphicsPipelines(.null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&pipeline));
        return pipeline;
    }

    fn createTextDescriptorPool(self: *VulkanRenderer) !vk.DescriptorPool {
        // Descriptor sets are allocated from pools. This renderer needs exactly
        // one set with exactly one combined image sampler for the font atlas.
        const pool_size = vk.DescriptorPoolSize{
            .type = .combined_image_sampler,
            .descriptor_count = 1,
        };
        return try self.dev.createDescriptorPool(&.{
            .flags = .{},
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&pool_size),
        }, null);
    }

    fn createTextDescriptorSet(self: *VulkanRenderer) !vk.DescriptorSet {
        var descriptor_set: vk.DescriptorSet = undefined;
        try self.dev.allocateDescriptorSets(&.{
            .descriptor_pool = self.text_descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&self.text_descriptor_set_layout),
        }, @ptrCast(&descriptor_set));

        // The descriptor set stores the concrete font texture handles that match
        // binding 0 in the text descriptor set layout and text.frag.
        const image_info = vk.DescriptorImageInfo{
            .sampler = self.bitmap_font_texture.sampler,
            .image_view = self.bitmap_font_texture.view,
            .image_layout = .shader_read_only_optimal,
        };
        const write = vk.WriteDescriptorSet{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        self.dev.updateDescriptorSets(1, @ptrCast(&write), 0, null);
        return descriptor_set;
    }

    fn createBitmapFontTextureResources(self: *VulkanRenderer) !FontTextureResources {
        const width = monogram_font.texture_width;
        const height = monogram_font.texture_height;
        const pixel_count: usize = width * height;
        std.debug.assert(monogram_font.data.len == monogram_font.glyph_count);
        std.debug.assert(monogram_font.data[0].len == monogram_font.glyph_height);

        // Convert the packed 1-bit glyph data into an RGBA atlas. RGB stays
        // white and alpha becomes the glyph mask sampled by the text shader.
        const rgba_pixels = try self.allocator.alloc(u8, pixel_count * 4);
        defer self.allocator.free(rgba_pixels);
        @memset(rgba_pixels, 0);

        for (monogram_font.data, 0..) |glyph_rows, glyph_index| {
            const atlas_x = monogram_font.glyph_padding + (glyph_index % monogram_font.glyphs_per_row) * monogram_font.glyph_stride_x;
            const atlas_y = monogram_font.glyph_padding + (glyph_index / monogram_font.glyphs_per_row) * monogram_font.glyph_stride_y;

            for (glyph_rows, 0..) |bits, row| {
                for (0..monogram_font.glyph_width) |x| {
                    const mask = @as(u8, 1) << @intCast(x);
                    const pixel_index = (atlas_y + row) * width + atlas_x + x;
                    const alpha: u8 = if ((bits & mask) != 0) 255 else 0;
                    rgba_pixels[pixel_index * 4 + 0] = 255;
                    rgba_pixels[pixel_index * 4 + 1] = 255;
                    rgba_pixels[pixel_index * 4 + 2] = 255;
                    rgba_pixels[pixel_index * 4 + 3] = alpha;
                }
            }
        }

        // Device-local images are fast for the GPU but not directly writable by
        // the CPU, so upload through a temporary CPU-visible staging buffer.
        var staging = try self.createBuffer(
            rgba_pixels.len,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
            true,
        );
        defer staging.deinit(self);

        const staging_bytes: [*]u8 = @ptrCast(@alignCast(staging.mapped.?));
        @memcpy(staging_bytes[0..rgba_pixels.len], rgba_pixels);

        // The image is the GPU-owned texture. It can receive transfer copies and
        // later be sampled by the fragment shader.
        const image = try self.dev.createImage(&.{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .initial_layout = .undefined,
        }, null);
        errdefer self.dev.destroyImage(image, null);

        const requirements = self.dev.getImageMemoryRequirements(image);
        const memory = try self.allocate(requirements, .{ .device_local_bit = true });
        errdefer self.dev.freeMemory(memory, null);
        try self.dev.bindImageMemory(image, memory, 0);

        try self.uploadFontTexture(image, staging.buffer, width, height);

        // An image view describes how shaders see the image. Here it is a simple
        // 2D color texture with one mip level and one array layer.
        const view = try self.dev.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer self.dev.destroyImageView(view, null);

        // Nearest filtering preserves the pixel-font shape instead of smoothing
        // it like a photographic texture.
        const sampler = try self.dev.createSampler(&.{
            .flags = .{},
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = .false,
        }, null);

        return .{
            .image = image,
            .memory = memory,
            .view = view,
            .sampler = sampler,
        };
    }

    fn uploadFontTexture(self: *VulkanRenderer, image: vk.Image, staging_buffer: vk.Buffer, width: u32, height: u32) !void {
        // Texture upload is a short-lived GPU job, separate from the per-frame
        // command buffer, so allocate a temporary command buffer for it.
        var command_buffer: vk.CommandBuffer = undefined;
        try self.dev.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer));
        defer self.dev.freeCommandBuffers(self.command_pool, 1, @ptrCast(&command_buffer));

        try self.dev.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

        // Images must be in a layout compatible with the operation being done.
        // Move from undefined contents into transfer-destination layout before
        // copying pixels from the staging buffer.
        transitionImageLayout(self.dev, command_buffer, image, .undefined, .transfer_dst_optimal);

        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        };
        self.dev.cmdCopyBufferToImage(command_buffer, staging_buffer, image, .transfer_dst_optimal, 1, @ptrCast(&region));

        // After the copy, move the image into the read-only layout expected by
        // the text fragment shader.
        transitionImageLayout(self.dev, command_buffer, image, .transfer_dst_optimal, .shader_read_only_optimal);

        try self.dev.endCommandBuffer(command_buffer);

        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        };
        try self.dev.queueSubmit(self.graphics_queue.handle, 1, @ptrCast(&submit_info), .null_handle);
        // Synchronous upload keeps initialization simple: when this returns the
        // font texture is ready for descriptor setup and future draw calls.
        try self.dev.queueWaitIdle(self.graphics_queue.handle);
    }

    fn windowFramebufferExtent(self: *const VulkanRenderer) vk.Extent2D {
        // GLFW returns signed dimensions; clamp negatives defensively before
        // converting to Vulkan's unsigned extent type.
        const framebuffer_size = self.window.getFramebufferSize();
        return .{
            .width = @intCast(@max(framebuffer_size[0], 0)),
            .height = @intCast(@max(framebuffer_size[1], 0)),
        };
    }
};

const Queue = struct {
    handle: vk.Queue = .null_handle,
    family: u32 = 0,

    fn init(device: Device, family: u32) Queue {
        // Queue index 0 is enough because each requested family asked the device
        // for one queue during logical-device creation.
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

const SwapchainGeneration = struct {
    handle: vk.SwapchainKHR,
    surface_format: vk.SurfaceFormatKHR,
    extent: vk.Extent2D,
    min_image_count: u32,
    image_views: []vk.ImageView,
    framebuffers: []vk.Framebuffer,

    fn create(renderer: *VulkanRenderer, old_handle: vk.SwapchainKHR, surface_format: vk.SurfaceFormatKHR) !SwapchainGeneration {
        // Surface capabilities are the window system's constraints: min/max image
        // count, supported extents, transforms, and similar presentation rules.
        const caps = try renderer.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(renderer.pdev, renderer.surface);
        const extent = findActualExtent(caps, renderer.windowFramebufferExtent());
        if (extent.width == 0 or extent.height == 0) return error.InvalidSurfaceDimensions;

        const supported_format = try findSurfaceFormat(renderer, renderer.allocator, surface_format);
        const present_mode = try findPresentMode(renderer, renderer.allocator);

        // Asking for one more image than the minimum gives the GPU/presenter a
        // little buffering room, capped by the surface if it has a maximum.
        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0) image_count = @min(image_count, caps.max_image_count);

        // If graphics and present use different queue families, images must be
        // shareable by both families. Otherwise exclusive sharing is cheaper.
        const qfi = [_]u32{ renderer.graphics_queue.family, renderer.present_queue.family };
        const sharing_mode: vk.SharingMode = if (renderer.graphics_queue.family != renderer.present_queue.family) .concurrent else .exclusive;
        const concurrent = sharing_mode == .concurrent;

        const handle = try renderer.dev.createSwapchainKHR(&.{
            .surface = renderer.surface,
            .min_image_count = image_count,
            .image_format = supported_format.format,
            .image_color_space = supported_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = sharing_mode,
            .queue_family_index_count = if (concurrent) qfi.len else 0,
            .p_queue_family_indices = if (concurrent) &qfi else undefined,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = .true,
            .old_swapchain = old_handle,
        }, null);
        errdefer renderer.dev.destroySwapchainKHR(handle, null);

        const images = try renderer.dev.getSwapchainImagesAllocKHR(handle, renderer.allocator);
        defer renderer.allocator.free(images);

        // Swapchain images are owned by Vulkan, but we create image views so they
        // can be used as framebuffer attachments.
        const image_views = try renderer.allocator.alloc(vk.ImageView, images.len);
        errdefer renderer.allocator.free(image_views);

        var image_view_count: usize = 0;
        errdefer for (image_views[0..image_view_count]) |view| renderer.dev.destroyImageView(view, null);

        for (images, image_views) |image, *view_out| {
            view_out.* = try renderer.dev.createImageView(&.{
                .image = image,
                .view_type = .@"2d",
                .format = supported_format.format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);
            image_view_count += 1;
        }

        const framebuffers = try renderer.allocator.alloc(vk.Framebuffer, image_views.len);
        errdefer renderer.allocator.free(framebuffers);

        var framebuffer_count: usize = 0;
        errdefer for (framebuffers[0..framebuffer_count]) |framebuffer| renderer.dev.destroyFramebuffer(framebuffer, null);

        // Each framebuffer pairs the render pass with one concrete swapchain
        // image view. beginFrame picks the framebuffer matching the acquired image.
        for (framebuffers, image_views) |*framebuffer_out, image_view| {
            framebuffer_out.* = try renderer.dev.createFramebuffer(&.{
                .render_pass = renderer.render_pass,
                .attachment_count = 1,
                .p_attachments = @ptrCast(&image_view),
                .width = extent.width,
                .height = extent.height,
                .layers = 1,
            }, null);
            framebuffer_count += 1;
        }

        return .{
            .handle = handle,
            .surface_format = supported_format,
            .extent = extent,
            .min_image_count = @max(caps.min_image_count, 2),
            .image_views = image_views,
            .framebuffers = framebuffers,
        };
    }

    fn deinit(self: *SwapchainGeneration, renderer: *VulkanRenderer) void {
        // Destroy the objects we created around swapchain images before destroying
        // the swapchain handle itself.
        for (self.framebuffers) |framebuffer| renderer.dev.destroyFramebuffer(framebuffer, null);
        renderer.allocator.free(self.framebuffers);

        for (self.image_views) |view| renderer.dev.destroyImageView(view, null);
        renderer.allocator.free(self.image_views);

        if (self.handle != .null_handle) renderer.dev.destroySwapchainKHR(self.handle, null);
        self.* = undefined;
    }
};

const BufferResource = struct {
    buffer: vk.Buffer = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    mapped: ?*anyopaque = null,
    size: vk.DeviceSize = 0,

    fn deinit(self: *BufferResource, renderer: *VulkanRenderer) void {
        // Mapped memory must be unmapped before freeing the device allocation.
        if (self.mapped != null) {
            renderer.dev.unmapMemory(self.memory);
            self.mapped = null;
        }
        if (self.buffer != .null_handle) renderer.dev.destroyBuffer(self.buffer, null);
        if (self.memory != .null_handle) renderer.dev.freeMemory(self.memory, null);
        self.* = .{};
    }
};

const FontTextureResources = struct {
    image: vk.Image = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    view: vk.ImageView = .null_handle,
    sampler: vk.Sampler = .null_handle,

    fn deinit(self: *FontTextureResources, renderer: *VulkanRenderer) void {
        // The view and sampler reference the image, and the image references the
        // memory allocation, so tear them down in that order.
        if (self.sampler != .null_handle) renderer.dev.destroySampler(self.sampler, null);
        if (self.view != .null_handle) renderer.dev.destroyImageView(self.view, null);
        if (self.image != .null_handle) renderer.dev.destroyImage(self.image, null);
        if (self.memory != .null_handle) renderer.dev.freeMemory(self.memory, null);
        self.* = .{};
    }
};

fn createInstance(vkb: *const BaseWrapper) !vk.Instance {
    // GLFW tells us which instance extensions are required for creating a window
    // surface on the current platform, such as X11/Wayland/Win32 surface support.
    const extension_names = try zglfw.getRequiredInstanceExtensions();

    const app_info = vk.ApplicationInfo{
        .p_application_name = app_name,
        .application_version = versionToU32(vk.makeApiVersion(0, 0, 0, 0)),
        .p_engine_name = app_name,
        .engine_version = versionToU32(vk.makeApiVersion(0, 0, 0, 0)),
        .api_version = versionToU32(vk.API_VERSION_1_3),
    };

    return try vkb.createInstance(&.{
        .flags = .{},
        .p_application_info = &app_info,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @intCast(extension_names.len),
        .pp_enabled_extension_names = extension_names.ptr,
    }, null);
}

fn initializeDevice(instance: Instance, candidate: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1};
    // A logical device exposes the queue families selected from the physical GPU.
    // If graphics and present are the same family, queue_count below collapses
    // this to one queue-create entry.
    const queue_infos = [_]vk.DeviceQueueCreateInfo{
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };
    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family) 1 else 2;

    return try instance.createDevice(candidate.pdev, &.{
        .flags = .{},
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &queue_infos,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        .p_enabled_features = null,
    }, null);
}

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

fn pickPhysicalDevice(instance: Instance, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !DeviceCandidate {
    // Pick the first GPU that supports our required device extension, can present
    // to this window surface, and exposes the needed queue families.
    const devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(devices);

    for (devices) |device| {
        if (try checkSuitable(instance, device, allocator, surface)) |candidate| return candidate;
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(instance: Instance, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !?DeviceCandidate {
    // Suitability is intentionally minimal for the POC. Later we could score
    // devices by type, memory size, limits, or optional features.
    if (!try checkDeviceExtensionSupport(instance, pdev, allocator)) return null;
    if (!try checkSurfaceSupport(instance, pdev, surface)) return null;

    if (try allocateQueues(instance, pdev, allocator, surface)) |queues| {
        return .{
            .pdev = pdev,
            .queues = queues,
        };
    }

    return null;
}

fn allocateQueues(instance: Instance, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    // Graphics commands and presenting to the OS window are separate capabilities
    // in Vulkan. Many GPUs expose both on the same family, but not all do.
    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);
        if (graphics_family == null and properties.queue_flags.graphics_bit) graphics_family = family;
        if (present_family == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == .true) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return .{ .graphics_family = graphics_family.?, .present_family = present_family.? };
    }
    return null;
}

fn checkSurfaceSupport(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    // A usable presentation surface must expose at least one pixel format and one
    // present mode for the selected GPU.
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);
    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);
    return format_count > 0 and present_mode_count > 0;
}

fn checkDeviceExtensionSupport(instance: Instance, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator) !bool {
    // Device extensions are optional GPU/device features. Swapchain support is
    // mandatory for rendering into a window.
    const available = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(available);

    for (required_device_extensions) |required| {
        for (available) |extension| {
            if (std.mem.eql(u8, std.mem.span(required), std.mem.sliceTo(&extension.extension_name, 0))) break;
        } else {
            return false;
        }
    }
    return true;
}

fn findSurfaceFormat(renderer: *VulkanRenderer, allocator: std.mem.Allocator, required: ?vk.SurfaceFormatKHR) !vk.SurfaceFormatKHR {
    // Prefer a common sRGB swapchain format so color values are converted for the
    // monitor in the usual nonlinear color space.
    const default_preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };
    const formats = try renderer.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(renderer.pdev, renderer.surface, allocator);
    defer allocator.free(formats);

    const preferred = required orelse default_preferred;
    if (formats.len == 1 and formats[0].format == .undefined) return preferred;

    for (formats) |format| {
        if (std.meta.eql(format, preferred)) return preferred;
    }
    if (required != null) return error.SurfaceFormatUnavailable;
    return formats[0];
}

fn findPresentMode(renderer: *VulkanRenderer, allocator: std.mem.Allocator) !vk.PresentModeKHR {
    // Present mode controls how rendered images are queued to the display. Prefer
    // low-latency modes when available; FIFO is always supported and vsync-like.
    const modes = try renderer.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(renderer.pdev, renderer.surface, allocator);
    defer allocator.free(modes);

    const preferred = [_]vk.PresentModeKHR{ .mailbox_khr, .immediate_khr };
    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, modes, mode) != null) return mode;
    }
    return .fifo_khr;
}

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    // Some platforms dictate the swapchain size via current_extent. Others allow
    // the application to choose within min/max bounds.
    if (caps.current_extent.width != 0xFFFF_FFFF) return caps.current_extent;
    return .{
        .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

fn transitionImageLayout(device: Device, command_buffer: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
    // A pipeline barrier orders previous GPU work before future GPU work and
    // changes how an image's memory may be accessed. This helper only covers the
    // two transitions needed by font upload.
    const src_access: vk.AccessFlags = if (old_layout == .undefined) .{} else .{ .transfer_write_bit = true };
    const dst_access: vk.AccessFlags = if (new_layout == .transfer_dst_optimal) .{ .transfer_write_bit = true } else .{ .shader_read_bit = true };
    const src_stage: vk.PipelineStageFlags = if (old_layout == .undefined) .{ .top_of_pipe_bit = true } else .{ .transfer_bit = true };
    const dst_stage: vk.PipelineStageFlags = if (new_layout == .transfer_dst_optimal) .{ .transfer_bit = true } else .{ .fragment_shader_bit = true };

    const barrier = vk.ImageMemoryBarrier{
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    device.cmdPipelineBarrier(command_buffer, src_stage, dst_stage, .{}, 0, null, 0, null, 1, @ptrCast(&barrier));
}

fn getGlfwInstanceProcAddr(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction {
    // vulkan-zig needs a function loader; GLFW provides one that is already
    // wired up for the Vulkan loader used by the window.
    return @ptrCast(zglfw.getInstanceProcAddress(instance, procname));
}

fn loadZguiVulkanFunction(function_name: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    // zgui expects a C-style callback that resolves Vulkan function names. Pass
    // the renderer as user data so the callback can use the live instance.
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data.?));
    const function = zglfw.getInstanceProcAddress(self.instance.handle, function_name) orelse return null;
    return @ptrCast(@constCast(function));
}

fn imguiHandle(handle: anytype) zgui.backend.VkHandle {
    // The zgui backend type-erases Vulkan handles as pointers. Vulkan-zig wraps
    // them as integer-like enums, so convert through the integer value.
    const value = @intFromEnum(handle);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(value)));
}

fn versionToU32(version: vk.Version) u32 {
    return @bitCast(version);
}

const Bounds = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

const BitmapGlyph = struct {
    atlas_bounds: Bounds,
    width: f32,
    height: f32,
};

fn bitmapGlyph(codepoint: u21) ?BitmapGlyph {
    // Map a Unicode codepoint into the monogram bitmap atlas. Unsupported
    // codepoints return null and callers can fall back to '?'.
    if (codepoint < monogram_font.first_codepoint) return null;
    const glyph_index = codepoint - monogram_font.first_codepoint;
    if (glyph_index >= monogram_font.glyph_count) return null;

    const x = monogram_font.glyph_padding + (glyph_index % monogram_font.glyphs_per_row) * monogram_font.glyph_stride_x;
    const y = monogram_font.glyph_padding + (glyph_index / monogram_font.glyphs_per_row) * monogram_font.glyph_stride_y;

    return .{
        .atlas_bounds = .{
            .left = @floatFromInt(x),
            .top = @floatFromInt(y),
            .right = @floatFromInt(x + monogram_font.glyph_width),
            .bottom = @floatFromInt(y + monogram_font.glyph_height),
        },
        .width = monogram_font.glyph_width,
        .height = monogram_font.glyph_height,
    };
}

fn glyphInstance(
    position: Vec2,
    size: Vec2,
    atlas_bounds: Bounds,
    atlas_width: f32,
    atlas_height: f32,
    color: [4]f32,
) GlyphInstance {
    // Shaders sample textures using normalized UV coordinates in the 0..1 range,
    // while the font metadata stores atlas bounds in pixels.
    const uv_left = atlas_bounds.left / atlas_width;
    const uv_top = atlas_bounds.top / atlas_height;
    const uv_right = atlas_bounds.right / atlas_width;
    const uv_bottom = atlas_bounds.bottom / atlas_height;

    return .{
        .position = .{ position.x, position.y },
        .size = .{ size.x, size.y },
        .uv_min = .{ uv_left, uv_top },
        .uv_max = .{ uv_right, uv_bottom },
        .color = color,
    };
}

fn rectangleInstance(rectangle: DrawRectangle) RectangleInstance {
    return .{
        .position = .{ rectangle.rectangle.position.x, rectangle.rectangle.position.y },
        .size = .{ rectangle.rectangle.size.x, rectangle.rectangle.size.y },
        .color = colorComponents(rectangle.color),
    };
}

fn colorComponents(color: Color) [4]f32 {
    return .{
        color.r,
        color.g,
        color.b,
        color.a,
    };
}
