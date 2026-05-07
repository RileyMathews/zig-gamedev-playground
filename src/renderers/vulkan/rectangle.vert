#version 450

// One input record is read per rectangle instance, not per vertex. The shader
// generates the six quad corners itself from gl_VertexIndex.
layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_size;
layout(location = 2) in vec4 in_color;

// Pushed once per frame by renderer.zig so pixel coordinates can be converted
// into Vulkan clip space, whose visible range is -1..1 on each axis.
layout(push_constant) uniform FrameConstants {
    vec2 framebuffer_size;
} frame;

layout(location = 0) out vec4 out_color;

// The renderer draws a quad as two triangles: vertices 0,1,2 and 3,4,5.
// Returned values are local corners in 0..1 rectangle space.
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

// Public renderer coordinates are framebuffer pixels measured from top-left.
// With this Vulkan viewport setup, top-left maps to clip coordinate (-1, -1)
// and bottom-right maps to (1, 1).
vec2 screenToClip(vec2 position) {
    return vec2(
        position.x / frame.framebuffer_size.x * 2.0 - 1.0,
        position.y / frame.framebuffer_size.y * 2.0 - 1.0
    );
}

void main() {
    // Expand the instance's top-left position and size into one concrete corner
    // of the rectangle, then let rasterization fill the two triangles.
    vec2 pixel_position = in_position + quadCorner(gl_VertexIndex) * in_size;

    gl_Position = vec4(screenToClip(pixel_position), 0.0, 1.0);
    out_color = in_color;
}
