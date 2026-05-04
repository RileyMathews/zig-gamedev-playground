const glfw = @import("zglfw");

pub fn main() !void {
    try glfw.init();
    defer glfw.terminate();

    const window = try glfw.createWindow(600, 600, "zig-gamedev: minimal_glfw_gl", null, null);
    defer window.destroy();

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    while (!window.shouldClose()) {
        glfw.pollEvents();

        window.swapBuffers();
    }
}
