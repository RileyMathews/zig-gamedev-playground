#version 450

// Interpolated color from the vertex shader. For rectangles every corner has the
// same value, so the whole quad becomes one solid color.
layout(location = 0) in vec4 in_color;

layout(location = 0) out vec4 out_color;

void main() {
    // Fragment shaders run for covered pixels. Writing this output updates the
    // swapchain color attachment selected by the current render pass.
    out_color = in_color;
}
