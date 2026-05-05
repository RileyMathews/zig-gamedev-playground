struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
};

struct FrameUniforms {
    framebuffer_size: vec2<f32>,
};

@group(0) @binding(0) var<uniform> frame: FrameUniforms;

fn quad_corner(vertex_index: u32) -> vec2<f32> {
    let corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0),
        vec2<f32>(0.0, 1.0),
        vec2<f32>(1.0, 0.0),
        vec2<f32>(1.0, 0.0),
        vec2<f32>(0.0, 1.0),
        vec2<f32>(1.0, 1.0),
    );
    return corners[vertex_index];
}

fn screen_to_clip(position: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(
        position.x / frame.framebuffer_size.x * 2.0 - 1.0,
        1.0 - position.y / frame.framebuffer_size.y * 2.0,
    );
}

@vertex fn vs_main(
    @location(0) position: vec2<f32>,
    @location(1) size: vec2<f32>,
    @location(2) color: vec4<f32>,
    @builtin(vertex_index) vertex_index: u32,
) -> VertexOutput {
    let pixel_position = position + quad_corner(vertex_index) * size;

    var output: VertexOutput;
    output.position = vec4<f32>(screen_to_clip(pixel_position), 0.0, 1.0);
    output.color = color;
    return output;
}

@fragment fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    return input.color;
}
