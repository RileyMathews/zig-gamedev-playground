// The vertex shader runs once for each vertex drawn. Instead of reading
// a vertex buffer, it uses the built-in vertex index to pick one of
// three hard-coded clip-space positions.
@vertex fn vs_main(@builtin(vertex_index) vertex_index: u32) -> @builtin(position) vec4<f32> {
    // Coordinates are in clip space: x/y range from -1 to 1 on screen.
    let positions = array<vec2<f32>, 3>(
        vec2<f32>(0.0, 0.6),
        vec2<f32>(-0.6, -0.6),
        vec2<f32>(0.6, -0.6),
    );

    // WebGPU expects a vec4 position: x, y, z depth, and w perspective value.
    return vec4<f32>(positions[vertex_index], 0.0, 1.0);
}

// The fragment shader runs for every pixel covered by the triangle.
@fragment fn fs_main() -> @location(0) vec4<f32> {
    // Return solid black with full opacity.
    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
}
