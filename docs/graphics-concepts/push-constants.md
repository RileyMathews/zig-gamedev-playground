# Push Constants

Push constants are a small amount of data written directly into a Vulkan command buffer for shaders to read. They are useful for tiny values that change often.

## Concept

Most shader data is provided through buffers or descriptor sets. Push constants are different: they are embedded into the command stream itself.

They are best for small per-draw or per-frame values, such as:

- Transform indices.
- Flags.
- Small matrices.
- Screen or framebuffer size.

Push constants have strict size limits, but they avoid allocating and binding a separate buffer for a few bytes of data.

## Pipeline Layout Declaration

Before command buffers can push constants, the [graphics pipeline](graphics-pipelines.md) layout must declare which byte ranges exist and which shader stages can read them.

This declaration is part of pipeline compatibility. If a shader expects push constants, the pipeline layout must match.

## Related Concepts

- [Shaders](shaders.md): read push constants as uniform-like values.
- [Graphics Pipelines](graphics-pipelines.md): pipeline layouts declare push-constant ranges.
- [Command Buffers](command-buffers.md): push constants are recorded as commands.
- [Framebuffer Pixels](framebuffer-pixels.md): the renderer pushes framebuffer size so shaders can convert pixels to clip space.

## Where It Appears In This Project

The renderer has one push-constant struct:

```zig
const FrameConstants = extern struct {
    framebuffer_size: [2]f32,
};
```

The pipeline layout declares the byte range for vertex shaders:

```zig
fn framePushConstantRange() vk.PushConstantRange {
    return .{
        .stage_flags = .{ .vertex_bit = true },
        .offset = 0,
        .size = @sizeOf(FrameConstants),
    };
}
```

`beginFrame` records the push-constant write after setting viewport and scissor:

```zig
self.dev.cmdPushConstants(
    command_buffer,
    self.pipeline_layout,
    .{ .vertex_bit = true },
    0,
    @sizeOf(FrameConstants),
    @ptrCast(&frame_constants),
);
```

Both `rectangle.vert` and `text.vert` declare the same push-constant block:

```glsl
layout(push_constant) uniform FrameConstants {
    vec2 framebuffer_size;
} frame;
```

They use it to convert top-left pixel coordinates into clip space.
