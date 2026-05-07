# Render Passes

A render pass describes how a set of framebuffer attachments are used during a period of rendering. It is one of Vulkan's ways of making render-target behavior explicit.

## Concept

A render pass answers questions like:

- Which attachments exist?
- What format does each attachment use?
- Should each attachment be cleared, loaded, stored, or ignored?
- What layout should each attachment be in at the beginning and end?
- Which subpasses read or write each attachment?

An attachment is usually an [image view](images-image-views-and-framebuffers.md) in a framebuffer. For this renderer, the only attachment is the current [swapchain](swapchains.md) image used as a color target.

## Load And Store Operations

Load and store operations describe what happens at render-pass boundaries.

Common load operations:

- `clear`: discard old contents and fill with a clear value.
- `load`: preserve previous contents.
- `dont_care`: old contents are irrelevant.

Common store operations:

- `store`: keep the rendered result after the pass.
- `dont_care`: result does not need to be preserved.

This renderer uses `clear` and `store`: clear the window image at frame start, then store it so presentation can display it.

## Layouts

Vulkan images have layouts. A layout describes how the GPU is expected to access the image. The same image memory may need different layouts when used as a transfer destination, shader texture, color attachment, or presentable image.

The render pass handles the swapchain image transition from an undefined initial layout to a presentation layout at the end. Texture upload uses explicit barriers instead; see [Vulkan Memory And Resources](vulkan-memory-and-resources.md).

## Subpasses

A subpass is a phase inside a render pass. More advanced renderers can use multiple subpasses for deferred rendering, post-processing, or efficient tile-memory usage.

This renderer uses one subpass: draw graphics commands into one color attachment.

## Related Concepts

- [Images, Image Views, And Framebuffers](images-image-views-and-framebuffers.md): render passes define attachment use, while framebuffers bind actual image views.
- [Graphics Pipelines](graphics-pipelines.md): Vulkan pipelines are created for a compatible render pass and subpass.
- [Command Buffers](command-buffers.md): render passes are begun and ended while recording commands.
- [Swapchains](swapchains.md): the render pass ultimately draws into a swapchain image.

## Where It Appears In This Project

The renderer creates one render pass in `createRenderPass`:

```zig
const color_attachment = vk.AttachmentDescription{
    .format = format,
    .samples = .{ .@"1_bit" = true },
    .load_op = .clear,
    .store_op = .store,
    .initial_layout = .undefined,
    .final_layout = .present_src_khr,
};
```

The attachment reference says subpass 0 writes to attachment 0 as a color target:

```zig
const color_attachment_ref = vk.AttachmentReference{
    .attachment = 0,
    .layout = .color_attachment_optimal,
};
```

`beginFrame` starts the render pass for the acquired swapchain image:

```zig
self.dev.cmdBeginRenderPass(command_buffer, &.{
    .render_pass = self.render_pass,
    .framebuffer = swapchain.framebuffers[image_index],
    .render_area = render_area,
    .clear_value_count = 1,
    .p_clear_values = @ptrCast(&clear),
}, .@"inline");
```

`Frame.end` ends the render pass before command-buffer submission:

```zig
renderer.dev.cmdEndRenderPass(self.command_buffer);
```

Both rectangle and text [graphics pipelines](graphics-pipelines.md) are created against this render pass, so they are compatible with drawing inside it.
