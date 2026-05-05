struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
};

@group(0) @binding(0) var font_atlas: texture_2d<f32>;
@group(0) @binding(1) var font_sampler: sampler;

@vertex fn vs_main(
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: vec4<f32>,
) -> VertexOutput {
    var output: VertexOutput;
    output.position = vec4<f32>(position, 0.0, 1.0);
    output.uv = uv;
    output.color = color;
    return output;
}

@fragment fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let sample = textureSample(font_atlas, font_sampler, input.uv);
    return vec4<f32>(input.color.rgb, input.color.a * sample.a);
}
