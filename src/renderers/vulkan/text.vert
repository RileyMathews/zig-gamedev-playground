#version 450

layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_size;
layout(location = 2) in vec2 in_uv_min;
layout(location = 3) in vec2 in_uv_max;
layout(location = 4) in vec4 in_color;

layout(push_constant) uniform FrameConstants {
    vec2 framebuffer_size;
} frame;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

vec2 quadCorner(int vertex_index) {
    const vec2 corners[6] = vec2[6](
        vec2(0.0, 0.0),
        vec2(0.0, 1.0),
        vec2(1.0, 0.0),
        vec2(1.0, 0.0),
        vec2(0.0, 1.0),
        vec2(1.0, 1.0)
    );
    return corners[vertex_index];
}

vec2 screenToClip(vec2 position) {
    return vec2(
        position.x / frame.framebuffer_size.x * 2.0 - 1.0,
        position.y / frame.framebuffer_size.y * 2.0 - 1.0
    );
}

void main() {
    vec2 corner = quadCorner(gl_VertexIndex);
    vec2 pixel_position = in_position + corner * in_size;

    gl_Position = vec4(screenToClip(pixel_position), 0.0, 1.0);
    out_uv = mix(in_uv_min, in_uv_max, corner);
    out_color = in_color;
}
