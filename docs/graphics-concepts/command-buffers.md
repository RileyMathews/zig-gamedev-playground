# Command Buffers

A command buffer is a recorded list of GPU commands. Instead of calling GPU operations immediately, Vulkan programs record commands into command buffers, then submit those command buffers to queues.

## Concept

Modern graphics APIs separate recording work from executing work. This gives applications explicit control over what the GPU will do and when that work is submitted.

Typical command-buffer commands include:

- Begin or end a [render pass](render-passes.md).
- Bind a [graphics pipeline](graphics-pipelines.md).
- Bind vertex or instance buffers.
- Bind [descriptor sets](descriptor-sets.md).
- Push constants.
- Draw.
- Copy buffers or images.
- Insert synchronization barriers.

Command buffers are allocated from command pools. A command pool is tied to a queue family because command buffers are intended for queues with compatible capabilities.

## Recording Versus Submission

Recording builds the command list on the CPU. Submission hands that list to a GPU queue.

This distinction matters because `drawRectangle` and `drawText` do not immediately record Vulkan commands in this renderer. They write CPU-side instance data and append draw ranges. The actual Vulkan draw commands are recorded later when `flushDraws` runs.

## One-Time And Reusable Work

Some command buffers are recorded every frame. Others are short-lived utility command buffers. This renderer uses both:

- One reusable frame command buffer for rendering.
- One temporary command buffer for uploading the font texture.

## Related Concepts

- [Graphics Pipelines](graphics-pipelines.md): command buffers bind pipelines before draw calls.
- [Render Passes](render-passes.md): drawing happens inside an active render pass.
- [Synchronization](synchronization.md): submitted command buffers are ordered with semaphores and fences.
- [Vulkan Memory And Resources](vulkan-memory-and-resources.md): texture upload records copy and layout-transition commands.
- [Instance Data](instance-data.md): command buffers bind instance buffers before drawing.

## Where It Appears In This Project

The renderer creates a command pool and one primary frame command buffer during initialization:

```zig
self.command_pool = try self.dev.createCommandPool(&.{
    .flags = .{ .reset_command_buffer_bit = true },
    .queue_family_index = self.graphics_queue.family,
}, null);

try self.dev.allocateCommandBuffers(&.{
    .command_pool = self.command_pool,
    .level = .primary,
    .command_buffer_count = 1,
}, @ptrCast(&self.command_buffer));
```

Every frame, `beginFrame` resets and begins that command buffer:

```zig
self.dev.resetCommandBuffer(command_buffer, .{});
self.dev.beginCommandBuffer(command_buffer, &.{});
```

Draw commands are recorded during `Frame.flushDraws`, `flushRectangles`, and `flushText`:

```zig
renderer.dev.cmdBindPipeline(self.command_buffer, .graphics, renderer.rectangle_pipeline);
renderer.dev.cmdBindVertexBuffers(self.command_buffer, 0, 1, @ptrCast(&instance_buffer.buffer), &offset);
renderer.dev.cmdDraw(self.command_buffer, quad_vertex_count, @intCast(range.count), 0, 0);
```

`Frame.end` ends the command buffer and submits it:

```zig
renderer.dev.endCommandBuffer(self.command_buffer);
renderer.dev.queueSubmit(renderer.graphics_queue.handle, 1, @ptrCast(&submit_info), frame_fence);
```

`uploadFontTexture` allocates a temporary command buffer for one-time copy work. That buffer records image layout transitions, copies staging-buffer bytes into the font image, and is freed after submission completes.
