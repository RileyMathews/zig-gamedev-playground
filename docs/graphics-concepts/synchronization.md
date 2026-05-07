# Synchronization

Synchronization is how a renderer tells the CPU, GPU queues, and presentation engine what must happen before what. Vulkan is explicit: it rarely guesses ordering for you.

## Concept

GPU work is asynchronous. Submitting commands does not mean they finish immediately. Presentation is also asynchronous; the window system may still be using an image when the application wants to render another frame.

Synchronization solves hazards such as:

- Rendering into a [swapchain](swapchains.md) image before it is available.
- Presenting an image before rendering has finished.
- Reusing a [command buffer](command-buffers.md) while the GPU is still executing it.
- Reading an image as a texture before a transfer copy into it has completed.

## Semaphores

Semaphores synchronize work between GPU queues or between the presentation engine and a queue.

This renderer uses semaphores for acquire and present ordering:

- `image_available`: signaled when the acquired swapchain image can be rendered into.
- `render_finished`: signaled when drawing is done and present may read the image.

## Fences

Fences synchronize GPU work back to the CPU.

This renderer uses `in_flight_fence` so the CPU knows when the previous frame's submitted command buffer is done. Because the renderer has one command buffer and one set of transient buffers, it waits before reusing them.

## Pipeline Barriers

Pipeline barriers synchronize work within GPU command execution. They can also transition image layouts.

The font upload path uses barriers to move the font image from undefined contents to transfer destination, then to shader-read-only. See [Vulkan Memory And Resources](vulkan-memory-and-resources.md).

## Related Concepts

- [Swapchains](swapchains.md): acquire and present require semaphore ordering.
- [Command Buffers](command-buffers.md): submitted command buffers are protected by fences before reuse.
- [Images, Image Views, And Framebuffers](images-image-views-and-framebuffers.md): images need layout and access ordering.
- [Vulkan Memory And Resources](vulkan-memory-and-resources.md): upload barriers make copied texture data visible to shaders.

## Where It Appears In This Project

Synchronization objects are stored on `VulkanRenderer`:

```zig
image_available: vk.Semaphore = .null_handle,
render_finished: vk.Semaphore = .null_handle,
in_flight_fence: vk.Fence = .null_handle,
```

They are created by `createSyncObjects`. The fence starts signaled so the first frame can proceed:

```zig
self.in_flight_fence = try self.dev.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
```

`beginFrame` waits for the previous submission:

```zig
_ = self.dev.waitForFences(1, @ptrCast(&frame_fence), .true, std.math.maxInt(u64));
```

Image acquisition signals `image_available`:

```zig
self.dev.acquireNextImageKHR(
    swapchain.handle,
    std.math.maxInt(u64),
    self.image_available,
    .null_handle,
);
```

Frame submission waits on `image_available` and signals `render_finished`:

```zig
.p_wait_semaphores = @ptrCast(&renderer.image_available),
.p_signal_semaphores = @ptrCast(&renderer.render_finished),
```

Presentation waits on `render_finished`:

```zig
.p_wait_semaphores = @ptrCast(&renderer.render_finished),
```

Font texture upload uses `transitionImageLayout` to record `cmdPipelineBarrier` calls around the copy.
