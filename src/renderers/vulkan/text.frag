#version 450

// Binding 0 matches renderer.zig's text descriptor set. It combines the font
// atlas image view and sampler used to read alpha for each glyph pixel.
layout(binding = 0) uniform sampler2D font_atlas;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;

layout(location = 0) out vec4 out_color;

void main() {
    // The atlas stores white pixels with alpha as the glyph mask. Tint comes from
    // the requested text color, while sampled alpha cuts out the glyph shape.
    vec4 sample_color = texture(font_atlas, in_uv);
    out_color = vec4(in_color.rgb, in_color.a * sample_color.a);
}
