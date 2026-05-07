# Images, Image Views, And Framebuffers

Images, image views, and framebuffers are closely related Vulkan concepts. An image is GPU image storage. An image view describes how that storage is interpreted. A framebuffer binds one or more image views to a [render pass](render-passes.md) so drawing commands have somewhere to write pixels.

## Images

An image is a block of GPU memory organized as pixels or texels. Images can be used for many things:

- Swapchain color targets.
- Texture sampling.
- Depth buffers.
- Offscreen render targets.
- Transfer destinations during upload.

Images have properties such as format, dimensions, mip levels, array layers, usage flags, and current layout.

In Vulkan, creating an image object does not automatically allocate memory for it. You create the image, query memory requirements, allocate compatible memory, and bind the memory. See [Vulkan Memory And Resources](vulkan-memory-and-resources.md).

## Image Views

An image view is a typed window into an image. It tells Vulkan how a shader or framebuffer should interpret the image:

- Is it 1D, 2D, 3D, or a cube map?
- Which format should be used?
- Which mip levels are visible?
- Which array layers are visible?
- Which aspect is used, such as color or depth?

You usually bind views, not raw images, to shaders and framebuffers.

## Framebuffers

A framebuffer is a set of concrete image views used as the attachments for a compatible [render pass](render-passes.md).

The render pass says what attachments exist and how they are used. The framebuffer says which actual image views are attached for a specific frame.

For a window renderer, there is usually one framebuffer per [swapchain](swapchains.md) image. When image index `N` is acquired, framebuffer `N` becomes the render target.

## Related Concepts

- [Swapchains](swapchains.md): provide the presentable images shown in the window.
- [Render Passes](render-passes.md): define how framebuffer attachments are used during drawing.
- [Descriptor Sets](descriptor-sets.md): bind image views and samplers for shader texture reads.
- [Vulkan Memory And Resources](vulkan-memory-and-resources.md): explains allocation, binding, and staging uploads.
- [Synchronization](synchronization.md): image layout transitions and acquire/present ownership require ordering.

## Where It Appears In This Project

Swapchain images are returned by Vulkan. The renderer does not create or own their memory. It creates image views for them in `SwapchainGeneration.create`:

```zig
const images = try renderer.dev.getSwapchainImagesAllocKHR(handle, renderer.allocator);

for (images, image_views) |image, *view_out| {
    view_out.* = try renderer.dev.createImageView(&.{
        .image = image,
        .view_type = .@"2d",
        .format = supported_format.format,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .level_count = 1,
            .layer_count = 1,
        },
    }, null);
}
```

Then it creates one framebuffer per image view:

```zig
for (framebuffers, image_views) |*framebuffer_out, image_view| {
    framebuffer_out.* = try renderer.dev.createFramebuffer(&.{
        .render_pass = renderer.render_pass,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&image_view),
        .width = extent.width,
        .height = extent.height,
        .layers = 1,
    }, null);
}
```

The font atlas is a different kind of image. The renderer creates it directly in `createBitmapFontTextureResources` with usage flags for transfer destination and shader sampling:

```zig
.usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
```

That image gets an image view and sampler, then the view and sampler are bound through a [descriptor set](descriptor-sets.md) so `text.frag` can sample glyph alpha.
