# Instance Data

Instance data is per-object input consumed by the GPU when drawing many copies of the same geometry. This renderer uses instance data to draw rectangles and text glyphs as repeated quads.

## Concept

A draw call can draw multiple instances. The vertex shader runs for every vertex of every instance. Some input data advances per vertex, and some input data advances per instance.

For 2D quads, most geometry is identical. Every rectangle and glyph is made of two triangles, which means six vertices. The changing data is not the corner pattern; it is the placement, size, color, and sometimes texture coordinates.

Instance data lets the renderer upload only the changing data:

- Position.
- Size.
- Color.
- UV bounds for glyphs.

Then the vertex shader combines that per-instance data with a generated local quad corner.

## Why This Is Useful

Without instancing, drawing 10,000 rectangles could require writing 60,000 vertices. With instancing, the renderer writes 10,000 compact instance records and asks the shader to generate the six corners for each instance.

This keeps the CPU-side data simple and reduces repeated vertex data.

## Batching And Ordering

Instance data works best when adjacent draw calls use the same [graphics pipeline](graphics-pipelines.md). This renderer batches consecutive rectangles together and consecutive glyph ranges together.

It still preserves draw order. If text appears between two rectangle draws, the renderer keeps them as separate commands so visual stacking remains correct.

## Related Concepts

- [Graphics Pipelines](graphics-pipelines.md): define instance-rate vertex input bindings and attributes.
- [Shaders](shaders.md): read instance data and generate final vertex positions.
- [Command Buffers](command-buffers.md): bind instance buffers and issue instanced draw calls.
- [Vulkan Memory And Resources](vulkan-memory-and-resources.md): explains the mapped buffers storing instance data.

## Where It Appears In This Project

Rectangle instance records are defined in `renderer.zig`:

```zig
const RectangleInstance = extern struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
};
```

Text glyph instance records include UV bounds:

```zig
const GlyphInstance = extern struct {
    position: [2]f32,
    size: [2]f32,
    uv_min: [2]f32,
    uv_max: [2]f32,
    color: [4]f32,
};
```

The buffers are created as vertex buffers and persistently mapped:

```zig
self.rectangle_instance_buffer = try self.createBuffer(
    @sizeOf(RectangleInstance) * max_rectangles_per_frame,
    .{ .vertex_buffer_bit = true },
    .{ .host_visible_bit = true, .host_coherent_bit = true },
    true,
);
```

`Frame.drawRectangle` writes one instance:

```zig
const mapped_instances: [*]RectangleInstance = @ptrCast(@alignCast(instance_buffer.mapped.?));
mapped_instances[self.rectangle_count] = rectangleInstance(rectangle);
```

`flushRectangles` draws a range of instances:

```zig
renderer.dev.cmdDraw(self.command_buffer, quad_vertex_count, @intCast(range.count), 0, 0);
```

The first argument is six vertices per quad. The second argument is the number of rectangle instances.
