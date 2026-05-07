# Renderer Introduction

This guide explains how the current renderer works and what graphics concepts it is built on. It is written for a developer who is comfortable with general programming, memory, APIs, and event loops, but is new to rendering pipelines and graphics APIs.

The renderer is intentionally small. It exposes a raylib-inspired API for drawing rectangles and bitmap text, while the implementation uses Vulkan directly enough to teach the main pieces of a modern explicit graphics API.

## Where The Code Lives

- `src/renderers/vulkan/renderer.zig`: the renderer implementation and public API.
- `src/renderers/vulkan/rectangle.vert`: vertex shader for rectangles.
- `src/renderers/vulkan/rectangle.frag`: fragment shader for rectangles.
- `src/renderers/vulkan/text.vert`: vertex shader for text glyph quads.
- `src/renderers/vulkan/text.frag`: fragment shader for text glyphs.
- `src/renderers/vulkan/monogram_font.zig`: packed bitmap font data used to build the font texture.
- `build.zig`: compiles GLSL shaders to SPIR-V and embeds them into the renderer module.
- `src/main.zig`: example usage of the renderer inside the application loop.

## The Big Idea

The public API tries to feel immediate-mode and simple:

```zig
var frame = renderer.beginFrame(render.Color.white) orelse continue;
defer frame.end();

frame.drawRectangle(.{
    .rectangle = .{
        .position = .{ .x = 100, .y = 100 },
        .size = .{ .x = 200, .y = 80 },
    },
    .color = render.Color.green,
});

frame.drawText(.{
    .text = "hello world",
    .position = .{ .x = 120, .y = 125 },
    .size = 24,
    .color = render.Color.black,
});
```

Under the hood, Vulkan does not work like a canvas where each call immediately draws pixels. The renderer translates those simple calls into:

- CPU-written instance-buffer data.
- A small ordered command list of rectangle and text ranges.
- Vulkan command-buffer commands.
- GPU pipeline execution.
- Presentation of a swapchain image to the OS window.

The renderer therefore has two personalities:

- Public side: simple draw calls using framebuffer pixels from the top-left.
- Implementation side: explicit Vulkan objects, synchronization, command recording, shader pipelines, and GPU resources.

## Core Graphics Concepts

The renderer uses a small set of graphics concepts repeatedly. This guide keeps the summaries short; the deeper concept pages live in [graphics-concepts/](graphics-concepts/README.md).

Read these when you want a standalone explanation plus the exact code locations where the concept appears in this project:

- [Framebuffer Pixels](graphics-concepts/framebuffer-pixels.md): the renderer's top-left pixel coordinate system and how shaders convert it to clip space.
- [Shaders](graphics-concepts/shaders.md): the GLSL programs that position quads and color pixels.
- [Instance Data](graphics-concepts/instance-data.md): the per-rectangle and per-glyph records written by draw calls.
- [Graphics Pipelines](graphics-concepts/graphics-pipelines.md): baked shader and fixed-function state for rectangles and text.
- [Command Buffers](graphics-concepts/command-buffers.md): recorded GPU command lists used for frames and texture upload.
- [Render Passes](graphics-concepts/render-passes.md): how Vulkan describes attachment usage during a frame.
- [Images, Image Views, And Framebuffers](graphics-concepts/images-image-views-and-framebuffers.md): the GPU image objects that receive pixels or hold textures.
- [Swapchains](graphics-concepts/swapchains.md): the rotating set of presentable window images.
- [Push Constants](graphics-concepts/push-constants.md): tiny per-frame values sent to shaders through the command buffer.
- [Descriptor Sets](graphics-concepts/descriptor-sets.md): shader resource bindings used by text rendering for the font atlas.
- [Synchronization](graphics-concepts/synchronization.md): semaphores, fences, and barriers that order GPU work.
- [Vulkan Memory And Resources](graphics-concepts/vulkan-memory-and-resources.md): buffer/image allocation, mapped memory, and staging uploads.

## Public API Overview

### `Renderer.init`

Creates all Vulkan state and persistent renderer resources.

You pass it an allocator and a GLFW window created with `.client_api = .no_api`, because Vulkan owns rendering instead of OpenGL.

### `Renderer.deinit`

Waits for the device to go idle, then destroys GPU and Vulkan resources. Vulkan objects often depend on each other, so cleanup is done roughly in reverse creation order.

### `Renderer.beginFrame`

Starts a frame and returns a `Frame` object. It can return `null` if rendering should be skipped, such as when the window is minimized or a fatal render error has occurred.

### `Frame.drawRectangle`

Adds a rectangle draw to the frame. This writes one `RectangleInstance` into the mapped rectangle instance buffer and appends or extends a rectangle draw command.

### `Frame.drawText`

Adds text to the frame. This parses UTF-8, maps each codepoint to a bitmap glyph, writes one `GlyphInstance` per visible glyph, and appends or extends a text draw command.

Spaces and tabs advance the text cursor but do not produce glyph quads.

### `Frame.end`

Flushes queued draw commands into Vulkan commands, ends the render pass, submits the command buffer, and presents the image.

Use `defer frame.end()` immediately after a successful `beginFrame` so every begun frame is submitted.

### `measureText`

Measures text on the CPU using the same bitmap glyph metrics that `drawText` uses. This is useful for centering or laying out text before drawing it.

## Initialization Lifecycle

`VulkanRenderer.init` builds the renderer in dependency order.

### 1. Load Vulkan Functions

`BaseWrapper.load(getGlfwInstanceProcAddr)` loads global Vulkan functions through GLFW's Vulkan function loader.

Vulkan functions are not all linked directly like normal C functions. Many are loaded dynamically based on the instance, device, and enabled extensions.

### 2. Create The Vulkan Instance

`createInstance` creates a `vk.Instance`, which is the application-level connection to Vulkan.

GLFW provides the required instance extensions for creating a surface on the current platform.

### 3. Create The Window Surface

`zglfw.createWindowSurface` creates a Vulkan surface for the GLFW window.

The surface is the bridge between Vulkan and the OS window system.

### 4. Pick A Physical Device

`pickPhysicalDevice` enumerates GPUs and accepts the first device that:

- Supports the swapchain device extension.
- Supports at least one surface format and present mode.
- Has a graphics queue family.
- Has a present queue family for this surface.

This selection is intentionally minimal. It is good enough for the current POC and easy to reason about.

### 5. Create The Logical Device And Queues

`initializeDevice` creates a logical device from the chosen physical device and requests one queue from the graphics and present families.

The renderer stores:

- `graphics_queue`: used to submit drawing and texture upload commands.
- `present_queue`: used to present rendered swapchain images.

On many systems these are the same queue family, but Vulkan does not require that.

### 6. Query Memory Properties

`mem_props` is stored so the renderer can allocate compatible memory later.

Vulkan separates resource handles from memory allocations. Creating a buffer or image is not enough; you must also find compatible memory, allocate it, and bind it.

### 7. Choose Surface Format And Create Render Pass

`findSurfaceFormat` prefers `b8g8r8a8_srgb` with `srgb_nonlinear_khr`, then falls back to the first available format.

`createRenderPass` creates a render pass compatible with that format.

### 8. Create Command Pool And Command Buffer

The command pool owns command-buffer memory for the graphics queue family.

The renderer allocates one primary command buffer and reuses it every frame.

### 9. Create Swapchain Generation

`SwapchainGeneration.create` creates the swapchain and all size-dependent objects around it:

- Swapchain handle.
- Swapchain image views.
- One framebuffer per image view.
- Swapchain extent.
- Surface format.

These are grouped into `SwapchainGeneration` because they are recreated together when the window size or presentation state changes.

### 10. Create Synchronization Objects

`createSyncObjects` creates the semaphores and fence used by the frame loop.

The fence starts signaled so the first frame does not wait forever for previous work that does not exist.

### 11. Create Pipeline Layout And Pipelines

The text descriptor set layout is created first because the shared pipeline layout includes it.

Then the renderer creates:

- Shared pipeline layout.
- Rectangle graphics pipeline.
- Text graphics pipeline.
- Text descriptor pool.

The shader bytecode for both pipelines comes from SPIR-V files generated by `build.zig`.

### 12. Create Persistent Instance Buffers

The rectangle and text instance buffers are created as:

- Vertex buffers.
- Host-visible memory.
- Host-coherent memory.
- Persistently mapped.

This means the CPU can write frame data directly into the buffers every frame without explicit flush calls.

### 13. Create Draw Command Storage

`draw_commands` stores the CPU-side ordered list of draw ranges for the current frame.

This list lets the renderer preserve draw order while batching consecutive draws of the same type.

### 14. Create Font Texture And Descriptor Set

`createBitmapFontTextureResources` expands packed bitmap glyph data into an RGBA texture atlas.

The upload path is:

- Build RGBA pixels in CPU memory.
- Copy them into a CPU-visible staging buffer.
- Create a device-local Vulkan image.
- Record a temporary command buffer.
- Transition image layout to transfer destination.
- Copy the staging buffer into the image.
- Transition image layout to shader-read-only.
- Create an image view.
- Create a nearest-filtered sampler.

`createTextDescriptorSet` then binds that image view and sampler to binding 0 for `text.frag`.

## Frame Lifecycle In Depth

This is the most important flow to understand when working in the renderer.

### Application Loop Shape

The app owns the window loop. The renderer owns GPU setup and per-frame rendering.

The usual loop shape is:

```zig
while (!window.shouldClose()) {
    zglfw.pollEvents();

    var frame = renderer.beginFrame(render.Color.white) orelse continue;
    defer frame.end();

    frame.drawRectangle(...);
    frame.drawText(...);
}
```

### Step 1. Poll Input And Update Game State

This happens outside the renderer. In `src/main.zig`, the app polls GLFW events, updates cursor state, toggles debug UI, and computes hovered tiles before rendering.

The renderer should only receive final draw requests for the current frame.

### Step 2. Begin The Frame

`renderer.beginFrame(clear_color)` does several things.

First it checks for conditions where rendering should not proceed:

- A fatal render error was recorded.
- The framebuffer size is zero, which commonly happens while minimized.

Then it checks whether the window framebuffer size differs from the current swapchain extent. If the size changed, it recreates the swapchain generation.

Next it waits for `in_flight_fence`. This is required because the renderer has only one command buffer and one set of frame resources. It cannot safely rewrite them until the GPU is done with the previous submission.

Then it acquires the next swapchain image:

```zig
const acquired = self.dev.acquireNextImageKHR(
    swapchain.handle,
    std.math.maxInt(u64),
    self.image_available,
    .null_handle,
);
```

This gives the renderer an `image_index`. The `image_available` semaphore will be signaled when the presentation engine is done with that image and the graphics queue can render into it.

Then it resets and begins the command buffer.

Then it begins the render pass using the framebuffer matching the acquired image:

```zig
self.dev.cmdBeginRenderPass(command_buffer, &.{
    .render_pass = self.render_pass,
    .framebuffer = swapchain.framebuffers[image_index],
    .render_area = render_area,
    .clear_value_count = 1,
    .p_clear_values = @ptrCast(&clear),
}, .@"inline");
```

This clears the swapchain image to `clear_color` and prepares it as the active color target.

Finally it sets dynamic viewport and scissor state and pushes `FrameConstants` so shaders know the framebuffer size.

### Step 3. Draw A Rectangle

`frame.drawRectangle` does not immediately call Vulkan. It writes data and queues work.

The public input is:

```zig
frame.drawRectangle(.{
    .rectangle = .{
        .position = .{ .x = 100, .y = 100 },
        .size = .{ .x = 200, .y = 80 },
    },
    .color = render.Color.green,
});
```

Under the hood:

- The function checks `max_rectangles_per_frame`.
- It appends or extends a rectangle `DrawCommand`.
- It writes a `RectangleInstance` into `rectangle_instance_buffer` at `rectangle_count`.
- It increments `rectangle_count`.

The instance data contains exactly what the shader needs:

```zig
const RectangleInstance = extern struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
};
```

Later, when commands are flushed, this becomes one Vulkan draw call for a range of rectangle instances:

```zig
cmdBindPipeline(rectangle_pipeline);
cmdBindVertexBuffers(rectangle_instance_buffer, byte_offset);
cmdDraw(quad_vertex_count, instance_count, 0, 0);
```

Each instance produces a six-vertex quad in `rectangle.vert`.

### Step 4. Draw Text

`frame.drawText` also writes instance data and queues work.

The public input is:

```zig
frame.drawText(.{
    .text = "hello world",
    .position = .{ .x = 120, .y = 130 },
    .size = 24,
    .color = render.Color.black,
});
```

Under the hood:

- It parses the string as UTF-8.
- It tracks a text cursor offset from the requested position.
- Newlines move the cursor down by `size + text_line_spacing`.
- Unsupported codepoints fall back to `?`.
- Spaces and tabs advance the cursor but do not create quads.
- Visible glyphs write `GlyphInstance` records into `text_instance_buffer`.
- A text `DrawCommand` range is appended or merged.

Each glyph instance contains:

```zig
const GlyphInstance = extern struct {
    position: [2]f32,
    size: [2]f32,
    uv_min: [2]f32,
    uv_max: [2]f32,
    color: [4]f32,
};
```

When flushed, text binds the text pipeline and descriptor set before drawing:

```zig
cmdBindPipeline(text_pipeline);
cmdBindDescriptorSets(text_descriptor_set);
cmdBindVertexBuffers(text_instance_buffer, byte_offset);
cmdDraw(quad_vertex_count, glyph_count, 0, 0);
```

The descriptor set matters because `text.frag` needs the font atlas texture.

### Step 5. Preserve Order While Batching

The renderer tracks draw commands separately from instance data.

If you call:

```zig
frame.drawRectangle(a);
frame.drawRectangle(b);
frame.drawText(label);
frame.drawRectangle(c);
```

The command list becomes conceptually:

```text
rectangles: instances a..b
text: label glyphs
rectangles: instance c
```

The first two rectangles batch together. The last rectangle does not merge with them because text was drawn in between. This preserves visual stacking order.

### Step 6. End The Frame

`frame.end()` is where queued work becomes submitted GPU work.

It first calls `flushDraws`, which walks the unflushed command ranges and records actual Vulkan draw commands.

Then it ends the render pass:

```zig
renderer.dev.cmdEndRenderPass(self.command_buffer);
```

Then it ends command-buffer recording.

Then it resets `in_flight_fence` so it can be signaled by the new GPU submission.

Then it submits the command buffer to the graphics queue:

```zig
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
```

This submission says:

- Wait for the swapchain image to be available.
- Run the command buffer.
- Signal `render_finished` when drawing is done.
- Signal `in_flight_fence` when the whole submission is done.

Finally it presents the swapchain image:

```zig
renderer.dev.queuePresentKHR(renderer.present_queue.handle, &.{
    .wait_semaphore_count = 1,
    .p_wait_semaphores = @ptrCast(&renderer.render_finished),
    .swapchain_count = 1,
    .p_swapchains = @ptrCast(&swapchain.handle),
    .p_image_indices = @ptrCast(&self.image_index),
});
```

Presentation waits for `render_finished`, so the OS never displays the image before the GPU is done drawing it.

If presentation reports the swapchain is suboptimal or out of date, the renderer recreates the swapchain.

## Complete Example Frame Loop

This example initializes GLFW and the renderer, then draws one rectangle and one `hello world` string every frame.

```zig
const std = @import("std");
const zglfw = @import("zglfw");
const render = @import("renderer");

pub fn main() !void {
    try zglfw.init();
    defer zglfw.terminate();

    // Vulkan renders directly to the window surface, so do not create an OpenGL
    // context for this window.
    zglfw.windowHint(.client_api, .no_api);

    const window = try zglfw.Window.create(800, 600, "renderer intro", null, null);
    defer window.destroy();

    const allocator = std.heap.page_allocator;
    var renderer = try render.Renderer.init(allocator, window);
    defer renderer.deinit();

    while (!window.shouldClose()) {
        zglfw.pollEvents();

        var frame = renderer.beginFrame(render.Color.white) orelse continue;
        defer frame.end();

        frame.drawRectangle(.{
            .rectangle = .{
                .position = .{ .x = 100, .y = 100 },
                .size = .{ .x = 220, .y = 90 },
            },
            .color = render.Color.green,
        });

        frame.drawText(.{
            .text = "hello world",
            .position = .{ .x = 120, .y = 130 },
            .size = 24,
            .color = render.Color.black,
        });
    }
}
```

Conceptually, one iteration of that loop does this:

```text
poll OS/window events
beginFrame
  wait for previous GPU work
  acquire swapchain image
  reset and begin command buffer
  begin render pass and clear image
  set viewport/scissor
  push framebuffer size
drawRectangle
  write RectangleInstance
  append rectangle DrawCommand
drawText
  write one GlyphInstance per visible glyph
  append text DrawCommand
end frame
  bind rectangle pipeline and draw rectangle instances
  bind text pipeline, bind font descriptor, draw glyph instances
  end render pass
  submit command buffer
  present image
```

## Rectangle Rendering Data Flow

For a single rectangle:

```text
Frame.drawRectangle
  -> RectangleInstance in mapped CPU-visible vertex buffer
  -> DrawCommand.rectangles range
  -> flushRectangles
  -> vkCmdBindPipeline(rectangle_pipeline)
  -> vkCmdBindVertexBuffers(rectangle_instance_buffer)
  -> vkCmdDraw(6 vertices, N instances)
  -> rectangle.vert generates quad corners and clip-space positions
  -> rectangle.frag writes solid color
  -> swapchain image receives pixels
```

The vertex shader receives per-instance attributes and `gl_VertexIndex`. It creates the rectangle corners by combining:

- Instance `position`.
- Instance `size`.
- One local quad corner from `gl_VertexIndex`.

Then it converts framebuffer pixels to clip space.

## Text Rendering Data Flow

For `hello world`:

```text
Frame.drawText
  -> UTF-8 codepoint iteration
  -> bitmapGlyph lookup for each visible codepoint
  -> GlyphInstance records in mapped CPU-visible vertex buffer
  -> DrawCommand.text range
  -> flushText
  -> vkCmdBindPipeline(text_pipeline)
  -> vkCmdBindDescriptorSets(text_descriptor_set)
  -> vkCmdBindVertexBuffers(text_instance_buffer)
  -> vkCmdDraw(6 vertices, glyph_count instances)
  -> text.vert generates glyph quad corners and UVs
  -> text.frag samples font atlas alpha
  -> alpha blending composites glyphs over the framebuffer
```

The font atlas is built once during initialization from `monogram_font.zig`. Each glyph has a pixel rectangle in that atlas. `GlyphInstance.uv_min` and `GlyphInstance.uv_max` convert that rectangle into normalized UV coordinates.

## Coordinate Conversion

The public API uses top-left pixel coordinates. Vulkan shaders output clip-space coordinates.

Clip-space coordinates use a visible range of approximately `-1..1`:

- X `-1` is left.
- X `1` is right.
- Y `-1` is top with this renderer's viewport setup.
- Y `1` is bottom with this renderer's viewport setup.

The shader conversion is:

```glsl
vec2 screenToClip(vec2 position) {
    return vec2(
        position.x / frame.framebuffer_size.x * 2.0 - 1.0,
        position.y / frame.framebuffer_size.y * 2.0 - 1.0
    );
}
```

This keeps the renderer's public API friendly while still feeding Vulkan the coordinate space it expects after vertex shading.

## Swapchain Recreation

Swapchains become invalid or suboptimal when presentation conditions change. Common causes are:

- Window resize.
- Minimize and restore.
- Display mode changes.
- Surface format or extent changes reported by the window system.

This renderer recreates the swapchain in two places:

- At the start of `beginFrame` if the framebuffer size differs from the swapchain extent.
- After present if Vulkan reports `suboptimal_khr` or `error_out_of_date_khr`.

`recreateSwapchain` waits for the device to be idle, creates a new `SwapchainGeneration`, swaps it into the renderer, and destroys the old generation.

Waiting for the whole device is simple and correct for now. A more advanced renderer would avoid a full-device wait and retire old swapchains only after relevant queued work completes.

## Debug UI Path

The renderer has optional zgui integration.

The key detail is that debug UI is rendered into the same command buffer and render pass as the game content. Before zgui emits its draw commands, `Frame.endDebugUi` calls `flushDraws()` so all queued game draws happen first. Then zgui records its commands, making debug UI appear on top.

## How To Read The Renderer

If you are new to the module, read it in this order:

1. Public data types near the top: `Color`, `Vec2`, `Rectangle`, `DrawRectangle`, `Text`.
2. `Frame.drawRectangle` and `Frame.drawText` to understand the public draw path.
3. `Frame.flushDraws`, `flushRectangles`, and `flushText` to see when Vulkan commands are recorded.
4. `VulkanRenderer.beginFrame` and `Frame.end` to understand frame boundaries.
5. `VulkanRenderer.init` to understand startup resource creation.
6. `createGraphicsPipeline`, `createRectanglePipeline`, and `createTextPipeline` to understand pipeline setup.
7. `createBitmapFontTextureResources` and `uploadFontTexture` to understand texture upload.
8. `SwapchainGeneration.create` and `recreateSwapchain` to understand window-size resources.

## Extending The Renderer

### Adding A New Simple Shape

For a shape that can be drawn as quads or instances:

- Add a new public draw type if needed.
- Add an instance struct describing the per-shape data.
- Add a buffer or reuse an existing compatible buffer.
- Add a draw command variant if it needs separate ordering or pipeline state.
- Add shaders if the existing rectangle pipeline is not enough.
- Add a pipeline if shader state, blending, descriptors, or vertex input differs.
- Add a `drawX` function that writes instances and appends commands.
- Add a `flushX` function that binds the right pipeline/resources and calls `cmdDraw`.

### Adding Texture Rendering

Texture rendering would introduce concepts already used by text:

- Texture image creation.
- Staging upload.
- Image layout transitions.
- Image view and sampler.
- Descriptor set layout and descriptor set.
- Fragment shader sampling.

Text is the best current reference for this path.

### Adding More Frames In Flight

The current renderer has one command buffer and one fence. Multiple frames in flight would likely require per-frame copies of:

- Command buffer.
- Fence.
- Image-available semaphore.
- Render-finished semaphore.
- Transient draw counts.
- Possibly per-frame instance buffers or ring-buffer offsets.

This can improve CPU/GPU overlap, but it also makes synchronization more complex.

## Common Pitfalls

- Do not use window logical size when you need framebuffer size.
- Do not record draw commands outside an active frame.
- Do not destroy Vulkan resources while the GPU might still reference them.
- Do not forget that `drawRectangle` and `drawText` queue work; actual Vulkan draw commands happen during flush.
- Do not reorder draw command batching in a way that changes visual stacking.
- Do not sample an image before it has been transitioned to `shader_read_only_optimal`.
- Do not assume graphics and present queues are always the same family.
- Do not add a shader resource without updating descriptor set layout, pipeline layout, descriptor set allocation, and shader bindings together.

## Current Design Tradeoffs

This renderer favors clarity and simple control flow over maximum throughput.

Current simplifying choices include:

- One command buffer reused every frame.
- One frame in flight.
- Device idle wait during swapchain recreation.
- Persistently mapped host-coherent instance buffers.
- Fixed maximum counts for rectangles, glyphs, and draw commands.
- No depth buffer.
- No multisampling.
- No general texture API yet.

These are good constraints for learning and for a POC. They keep the module small enough that a new developer can trace the entire path from a public draw call to presented pixels.
