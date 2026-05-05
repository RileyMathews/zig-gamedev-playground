struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
};

struct FrameUniforms {
    framebuffer_size: vec2<f32>,
};

@group(0) @binding(0) var<uniform> frame: FrameUniforms;
@group(1) @binding(0) var font_atlas: texture_2d<f32>;
@group(1) @binding(1) var font_sampler: sampler;

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
    @location(2) uv_min: vec2<f32>,
    @location(3) uv_max: vec2<f32>,
    @location(4) color: vec4<f32>,
    @builtin(vertex_index) vertex_index: u32,
) -> VertexOutput {
    let corner = quad_corner(vertex_index);
    let pixel_position = position + corner * size;

    var output: VertexOutput;
    output.position = vec4<f32>(screen_to_clip(pixel_position), 0.0, 1.0);
    output.uv = mix(uv_min, uv_max, corner);
    output.color = color;
    return output;
}

@fragment fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let sample = textureSample(font_atlas, font_sampler, input.uv);
    return vec4<f32>(input.color.rgb, input.color.a * sample.a);
}
