# Descriptor Sets

Descriptor sets bind shader resources such as textures, samplers, uniform buffers, and storage buffers. They are Vulkan's explicit way to say, "this shader binding refers to this actual resource."

## Concept

Shaders can declare resources. For example, a fragment shader may declare a sampled texture:

```glsl
layout(binding = 0) uniform sampler2D font_atlas;
```

That declaration is only an interface. It does not say which concrete texture image to sample. Vulkan fills that gap with descriptors.

A descriptor set layout describes the shape of a set:

- Which bindings exist.
- What descriptor type each binding uses.
- How many descriptors each binding contains.
- Which shader stages can access each binding.

A descriptor set is allocated from a descriptor pool and populated with actual resources matching the layout.

## Combined Image Samplers

This renderer uses a combined image sampler descriptor for text. It combines:

- An image view, which describes the font atlas image.
- A sampler, which describes filtering and addressing rules.
- An image layout, which says how the shader will read the image.

This descriptor is read by the text fragment [shader](shaders.md).

## Descriptor Sets And Pipeline Layouts

The [graphics pipeline](graphics-pipelines.md) layout must declare descriptor set layouts. This allows Vulkan to validate that bound descriptor sets match what shaders expect.

If you add a new shader resource, you usually need to update all of these together:

- GLSL binding declaration.
- Descriptor set layout.
- Descriptor pool sizes.
- Descriptor set allocation and update.
- Pipeline layout.
- Command-buffer binding code.

## Related Concepts

- [Shaders](shaders.md): declare resource bindings read through descriptor sets.
- [Graphics Pipelines](graphics-pipelines.md): pipeline layouts include descriptor set layouts.
- [Images, Image Views, And Framebuffers](images-image-views-and-framebuffers.md): image views are often bound through descriptors.
- [Vulkan Memory And Resources](vulkan-memory-and-resources.md): the font image and sampler are resources stored in the descriptor set.
- [Command Buffers](command-buffers.md): bind descriptor sets before drawing text.

## Where It Appears In This Project

Text rendering is the only current descriptor user.

`text.frag` declares binding 0:

```glsl
layout(binding = 0) uniform sampler2D font_atlas;
```

`createTextDescriptorSetLayout` declares the matching Vulkan binding:

```zig
const binding = vk.DescriptorSetLayoutBinding{
    .binding = 0,
    .descriptor_type = .combined_image_sampler,
    .descriptor_count = 1,
    .stage_flags = .{ .fragment_bit = true },
};
```

`createPipelineLayout` includes that set layout:

```zig
.set_layout_count = 1,
.p_set_layouts = @ptrCast(&self.text_descriptor_set_layout),
```

`createTextDescriptorSet` writes the concrete font texture resources into the descriptor set:

```zig
const image_info = vk.DescriptorImageInfo{
    .sampler = self.bitmap_font_texture.sampler,
    .image_view = self.bitmap_font_texture.view,
    .image_layout = .shader_read_only_optimal,
};
```

`flushText` binds the descriptor set before drawing glyph instances:

```zig
renderer.dev.cmdBindDescriptorSets(
    self.command_buffer,
    .graphics,
    renderer.pipeline_layout,
    0,
    1,
    @ptrCast(&renderer.text_descriptor_set),
    0,
    null,
);
```
