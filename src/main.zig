const glfw = @import("zglfw");
const std = @import("std");
const zopengl = @import("zopengl");

fn keyCallback(window: *glfw.Window, key: glfw.Key, scancode: c_int, action: glfw.Action, mods: glfw.Mods) callconv(.c) void {
    std.debug.print("{any}\n", .{window});
    std.debug.print("{any}\n", .{key});
    std.debug.print("{any}\n", .{scancode});
    std.debug.print("{any}\n", .{action});
    std.debug.print("{any}\n", .{mods});
}

pub fn main() !void {
    try glfw.init();
    defer glfw.terminate();

    const window = try glfw.createWindow(600, 600, "zig-gamedev: minimal_glfw_gl", null, null);
    defer window.destroy();

    glfw.makeContextCurrent(window);
    glfw.swapInterval(0);

    try zopengl.loadCoreProfile(glfw.getProcAddress, 4, 0);

    const gl = zopengl.bindings;

    const clear_color = [_]f32{ 0.2, 0.4, 0.8, 1.0};

    _ = window.setKeyCallback(keyCallback);

    while (!window.shouldClose()) {
        glfw.pollEvents();

        gl.clearBufferfv(gl.COLOR, 0, clear_color[0..].ptr);

        window.swapBuffers();
    }
}
