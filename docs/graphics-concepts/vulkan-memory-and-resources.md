# Vulkan Memory And Resources

Vulkan separates resource handles from the memory that backs them. This is one of the biggest differences from many higher-level APIs.

## Concept

A buffer or image handle describes a resource, but it does not necessarily own memory. The usual Vulkan pattern is:

```text
create resource handle
query memory requirements
choose compatible memory type
allocate memory
bind memory to resource
use resource
destroy resource and free memory
```

This explicit model gives applications control over where resources live and how memory is managed.

## Memory Properties

Different memory types have different properties.

Common properties include:

- `host_visible`: CPU can map and write/read it.
- `host_coherent`: CPU writes are automatically visible without explicit flushes.
- `device_local`: memory is local/preferred for GPU access.

CPU-visible memory is convenient for frequent writes. Device-local memory is usually better for GPU-only resources such as textures.

## Buffers

Buffers are linear memory resources. This renderer uses buffers for instance data and staging uploads.

The instance buffers are host-visible and host-coherent because the CPU rewrites them every frame. They are also used as vertex buffers by draw commands.

The staging buffer used for font upload is also host-visible and host-coherent, but it is used as a transfer source.

## Images

Images are structured pixel resources. This renderer uses images for the font atlas and receives swapchain images from the window system.

The font atlas image is device-local because it is read by the GPU during text rendering. The CPU uploads data through a staging buffer instead of mapping the image directly.

## Staging Uploads

Staging upload is a common pattern:

```text
write bytes into CPU-visible staging buffer
record GPU copy from staging buffer to device-local image
wait for copy to finish or synchronize future use
```

This keeps runtime sampling fast while still allowing CPU-generated texture data.

## Image Layouts

Images have layouts that must match how they are used. The font atlas starts with undefined contents, transitions to transfer destination for upload, then transitions to shader-read-only for sampling.

Layout transitions are a form of [synchronization](synchronization.md), recorded with pipeline barriers.

## Related Concepts

- [Instance Data](instance-data.md): stored in host-visible vertex buffers.
- [Images, Image Views, And Framebuffers](images-image-views-and-framebuffers.md): image resources need memory and views.
- [Descriptor Sets](descriptor-sets.md): bind image views and samplers created from image resources.
- [Synchronization](synchronization.md): barriers order transfers and shader reads.
- [Command Buffers](command-buffers.md): record buffer-to-image copies and barriers.

## Where It Appears In This Project

Resource allocation is centralized in `createBuffer`, `allocate`, and `findMemoryTypeIndex`.

`createBuffer` creates the buffer, allocates compatible memory, binds it, and optionally maps it:

```zig
const buffer = try self.dev.createBuffer(&.{
    .size = size,
    .usage = usage,
    .sharing_mode = .exclusive,
}, null);

const requirements = self.dev.getBufferMemoryRequirements(buffer);
const memory = try self.allocate(requirements, memory_flags);

try self.dev.bindBufferMemory(buffer, memory, 0);
const mapped = if (map_memory) try self.dev.mapMemory(memory, 0, size, .{}) else null;
```

`findMemoryTypeIndex` chooses a memory type supported by the resource and containing the requested flags:

```zig
if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and memory_type.property_flags.contains(flags)) {
    return @truncate(i);
}
```

The font atlas upload happens in `createBitmapFontTextureResources` and `uploadFontTexture`:

- CPU expands packed glyph data into RGBA pixels.
- A host-visible staging buffer receives those bytes.
- A device-local image is created and bound to memory.
- A temporary command buffer transitions layouts and copies data.
- An image view and sampler are created for shader sampling.

Cleanup helpers `BufferResource.deinit` and `FontTextureResources.deinit` destroy Vulkan handles and free memory in dependency order.
