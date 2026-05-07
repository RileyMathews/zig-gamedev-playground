# Graphics Pipelines

A graphics pipeline is a baked description of how draw calls turn input data into pixels. Vulkan makes pipelines explicit and relatively expensive to create so draw-time state changes can be predictable and cheap.

## Concept

A graphics pipeline combines programmable shader stages with fixed-function state.

Programmable state includes:

- Vertex shader.
- Fragment shader.

Fixed-function state includes:

- Vertex input layout.
- Primitive topology, such as triangle list.
- Viewport and scissor behavior.
- Rasterization settings.
- Multisampling settings.
- Depth/stencil settings.
- Color blending settings.
- Render-pass and subpass compatibility.

The pipeline layout is related but separate. It describes shader-visible resources such as [descriptor sets](descriptor-sets.md) and [push constants](push-constants.md).

## Why Pipelines Are Baked

Older graphics APIs often let programs mutate a lot of render state independently. Vulkan groups much of that state into pipeline objects. This gives the driver more information up front and reduces hidden work during drawing.

The tradeoff is that if shader inputs, blending, render pass compatibility, or fixed-function state differs, you usually need a different pipeline.

## Vertex Input

Vertex input state describes how bytes in bound buffers map to shader input locations.

This renderer uses instance-rate input. That means a `RectangleInstance` or `GlyphInstance` advances once per rectangle or glyph, not once per generated vertex. See [Instance Data](instance-data.md).

## Blending

Blending controls how fragment shader output combines with the existing framebuffer color.

Solid rectangles do not need blending; they overwrite their covered pixels. Text does need alpha blending because the font atlas stores glyph shapes in alpha. See [Shaders](shaders.md) and [Descriptor Sets](descriptor-sets.md).

## Related Concepts

- [Shaders](shaders.md): pipelines include shader modules and stage configuration.
- [Instance Data](instance-data.md): pipelines define how instance-buffer bytes map to shader inputs.
- [Render Passes](render-passes.md): pipelines are compatible with specific render passes and subpasses.
- [Descriptor Sets](descriptor-sets.md): pipeline layouts declare descriptor set layouts.
- [Push Constants](push-constants.md): pipeline layouts declare push-constant ranges.
- [Command Buffers](command-buffers.md): command buffers bind pipelines before drawing.

## Where It Appears In This Project

The renderer creates two pipelines:

- `rectangle_pipeline`
- `text_pipeline`

Both are created through `createGraphicsPipeline`, which takes shader bytecode, pipeline layout, vertex binding, attribute descriptions, and whether alpha blending is enabled.

Rectangle input uses `RectangleInstance`:

```zig
const binding = vk.VertexInputBindingDescription{
    .binding = 0,
    .stride = @sizeOf(RectangleInstance),
    .input_rate = .instance,
};
```

Text input uses `GlyphInstance`, which has more attributes because it includes UV bounds for the font atlas.

Both pipelines use triangle-list topology:

```zig
const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
    .topology = .triangle_list,
    .primitive_restart_enable = .false,
};
```

The rectangle pipeline disables alpha blending:

```zig
self.createGraphicsPipeline(..., false)
```

The text pipeline enables alpha blending:

```zig
self.createGraphicsPipeline(..., true)
```

During rendering, `flushRectangles` binds `rectangle_pipeline`, while `flushText` binds `text_pipeline` and the text descriptor set.
