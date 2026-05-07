# Shaders

Shaders are programs that run on the GPU. They are the programmable parts of the graphics pipeline. This renderer uses vertex shaders and fragment shaders.

## Concept

A vertex shader runs for each input vertex. It decides where that vertex is in clip space and can pass data to later stages.

A fragment shader runs for generated fragments, which are candidate pixels produced after triangles are rasterized. It computes the output color for each covered pixel.

The simplified path is:

```text
vertex shader -> triangle assembly -> rasterization -> fragment shader -> framebuffer
```

Shaders are compiled to SPIR-V for Vulkan. In this project, `build.zig` runs `glslc` and embeds the SPIR-V bytecode into the renderer module.

## Vertex Shader Responsibilities

The renderer's vertex shaders do two key jobs:

- Generate quad corners from `gl_VertexIndex`.
- Convert public [framebuffer pixel](framebuffer-pixels.md) positions into clip-space positions.

The renderer draws rectangles and glyphs as six vertices. Instead of storing a static quad vertex buffer, each vertex shader has a small local table of six corners.

## Fragment Shader Responsibilities

The rectangle fragment shader simply writes the interpolated color.

The text fragment shader samples the font atlas. The atlas is bound through a [descriptor set](descriptor-sets.md). Its alpha channel contains the glyph shape, so the shader combines requested text color with sampled alpha.

## Shader Inputs

Shader inputs are connected to pipeline vertex attributes. For example, `layout(location = 0) in vec2 in_position;` corresponds to attribute location 0 in the pipeline's vertex input state.

The CPU writes instance structs. The [graphics pipeline](graphics-pipelines.md) tells Vulkan how those struct fields map to shader locations. See [Instance Data](instance-data.md).

## Related Concepts

- [Graphics Pipelines](graphics-pipelines.md): pipelines package shader stages with fixed-function state.
- [Instance Data](instance-data.md): instance-buffer fields become shader inputs.
- [Descriptor Sets](descriptor-sets.md): provide sampled textures to shaders.
- [Push Constants](push-constants.md): provide framebuffer size to vertex shaders.
- [Framebuffer Pixels](framebuffer-pixels.md): are converted into clip space by vertex shaders.

## Where It Appears In This Project

Rectangle shaders:

- `src/renderers/vulkan/rectangle.vert`
- `src/renderers/vulkan/rectangle.frag`

Text shaders:

- `src/renderers/vulkan/text.vert`
- `src/renderers/vulkan/text.frag`

The rectangle vertex shader computes a corner position like this:

```glsl
vec2 pixel_position = in_position + quadCorner(gl_VertexIndex) * in_size;
gl_Position = vec4(screenToClip(pixel_position), 0.0, 1.0);
```

The text vertex shader also computes UV coordinates:

```glsl
out_uv = mix(in_uv_min, in_uv_max, corner);
```

The text fragment shader samples the atlas:

```glsl
vec4 sample_color = texture(font_atlas, in_uv);
out_color = vec4(in_color.rgb, in_color.a * sample_color.a);
```

`build.zig` compiles the shaders to SPIR-V and exposes them as anonymous imports:

```zig
addGlslShader(b, renderer_mod, "rectangle_vertex_shader", "src/renderers/vulkan/rectangle.vert", "rectangle.vert.spv");
```

`renderer.zig` embeds those binary imports and creates shader modules inside `createGraphicsPipeline`.
