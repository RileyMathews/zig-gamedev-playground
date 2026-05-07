# Swapchains

A swapchain is the connection between rendered images and the operating system window. It is a small set of images that the renderer cycles through. Each frame, Vulkan gives the renderer one image to draw into, then the renderer gives that image back to the presentation engine to display.

## Concept

Rendering directly into the image currently visible on screen would cause tearing and race conditions. Instead, windowed rendering uses backbuffers. The renderer draws into an image that is not currently being scanned out to the monitor, then presents that finished image.

Vulkan calls this set of presentable images a swapchain.

The basic flow is:

```text
acquire swapchain image
record and submit drawing commands for that image
present the image
repeat
```

A swapchain has important fixed properties:

- Image count.
- Image format.
- Color space.
- Extent, meaning width and height.
- Present mode.

Because these properties are fixed, the swapchain often needs to be recreated when the window changes size or presentation becomes out of date.

## Present Modes

Present mode controls how completed images are queued for display.

`fifo_khr` behaves like traditional vsync and is always available. The renderer prefers `mailbox_khr` or `immediate_khr` when available, then falls back to `fifo_khr`.

Present mode is related to [synchronization](synchronization.md) because the renderer must coordinate when an image is available for drawing and when it is safe to present.

## Swapchain Recreation

A swapchain can become invalid or suboptimal when:

- The window is resized.
- The window is minimized and restored.
- Display configuration changes.
- The surface reports new presentation requirements.

When that happens, size-dependent resources around the swapchain must also be recreated. In this renderer, that includes [image views and framebuffers](images-image-views-and-framebuffers.md).

## Related Concepts

- [Framebuffer Pixels](framebuffer-pixels.md): the swapchain extent defines the drawable framebuffer size.
- [Images, Image Views, And Framebuffers](images-image-views-and-framebuffers.md): each swapchain image gets an image view and framebuffer.
- [Render Passes](render-passes.md): render passes draw into swapchain-backed framebuffers.
- [Synchronization](synchronization.md): semaphores coordinate acquire, rendering, and present.

## Where It Appears In This Project

The swapchain is represented by `SwapchainGeneration` in `renderer.zig`:

```zig
const SwapchainGeneration = struct {
    handle: vk.SwapchainKHR,
    surface_format: vk.SurfaceFormatKHR,
    extent: vk.Extent2D,
    min_image_count: u32,
    image_views: []vk.ImageView,
    framebuffers: []vk.Framebuffer,
};
```

It is called a generation because all of these objects are recreated together. The renderer stores the current generation as:

```zig
swapchain: ?SwapchainGeneration = null,
```

Creation happens in `SwapchainGeneration.create`. It queries surface capabilities, chooses the actual extent, chooses a surface format, chooses a present mode, creates the Vulkan swapchain, then creates views and framebuffers for every swapchain image.

`VulkanRenderer.beginFrame` acquires the next image:

```zig
const acquired = self.dev.acquireNextImageKHR(
    swapchain.handle,
    std.math.maxInt(u64),
    self.image_available,
    .null_handle,
);
```

`Frame.end` presents the image:

```zig
renderer.dev.queuePresentKHR(renderer.present_queue.handle, &.{
    .wait_semaphore_count = 1,
    .p_wait_semaphores = @ptrCast(&renderer.render_finished),
    .swapchain_count = 1,
    .p_swapchains = @ptrCast(&swapchain.handle),
    .p_image_indices = @ptrCast(&self.image_index),
});
```

`recreateSwapchain` handles resizing and out-of-date presentation. It waits for the device to become idle, creates a new generation, installs it, and destroys the old generation.
