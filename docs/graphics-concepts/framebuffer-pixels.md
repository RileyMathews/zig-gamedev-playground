# Framebuffer Pixels

Framebuffer pixels are the actual drawable pixels in the image that will be shown on screen. They are not always the same as logical window coordinates. On high-DPI displays, a window might be 800 by 600 logical units while its framebuffer is 1600 by 1200 physical pixels.

Most 2D APIs expose a coordinate system that starts at the top-left and measures in pixels. This renderer follows that model because it keeps game/UI drawing simple and raylib-like.

## Concept

A framebuffer is a render target: memory that receives rendered pixels. In this project, the active framebuffer is backed by one image from the [swapchain](swapchains.md).

When drawing with this renderer, positions and sizes are expressed in framebuffer pixels:

```zig
render.Rectangle{
    .position = .{ .x = 100, .y = 50 },
    .size = .{ .x = 200, .y = 80 },
}
```

That means a rectangle whose top-left corner is 100 pixels from the left edge and 50 pixels from the top edge of the drawable framebuffer.

The GPU does not ultimately consume this top-left pixel coordinate system directly. Vertex [shaders](shaders.md) output positions in clip space, where visible coordinates are roughly `-1..1`. The renderer bridges those worlds by pushing the framebuffer size through [push constants](push-constants.md), then converting pixel coordinates to clip-space coordinates in GLSL.

## Why This Matters

Using framebuffer pixels gives predictable 2D placement. The alternative would be to expose Vulkan clip space or normalized coordinates in the public API, which would leak low-level graphics details into game code.

Framebuffer pixels also make text measurement and UI hit testing straightforward. If `measureText` returns a width of 96, that means 96 framebuffer pixels.

## Related Concepts

- [Swapchains](swapchains.md): provide the images whose size defines the current framebuffer size.
- [Images, Image Views, And Framebuffers](images-image-views-and-framebuffers.md): explains the image objects that receive the pixels.
- [Shaders](shaders.md): convert framebuffer pixel positions into clip-space positions.
- [Push Constants](push-constants.md): carry framebuffer size to the vertex shaders.

## Where It Appears In This Project

Public renderer types use framebuffer pixels:

- `Rectangle.position`
- `Rectangle.size`
- `Text.position`
- `Text.size`
- `FramebufferPixelSize`

`VulkanRenderer.framebufferPixelSize` returns the current [swapchain](swapchains.md) extent:

```zig
pub fn framebufferPixelSize(self: *VulkanRenderer) FramebufferPixelSize {
    const swapchain = self.swapchain.?;
    return .{
        .width = swapchain.extent.width,
        .height = swapchain.extent.height,
    };
}
```

`VulkanRenderer.beginFrame` pushes the framebuffer size into shaders:

```zig
const frame_constants = FrameConstants{ .framebuffer_size = .{
    @floatFromInt(swapchain.extent.width),
    @floatFromInt(swapchain.extent.height),
} };
```

`rectangle.vert` and `text.vert` convert pixels to clip space:

```glsl
vec2 screenToClip(vec2 position) {
    return vec2(
        position.x / frame.framebuffer_size.x * 2.0 - 1.0,
        position.y / frame.framebuffer_size.y * 2.0 - 1.0
    );
}
```

The main game loop in `src/main.zig` uses these coordinates directly for tile placement, hover testing, menu rectangles, and text placement.
