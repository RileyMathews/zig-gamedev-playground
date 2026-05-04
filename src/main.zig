const std = @import("std");
const zglfw = @import("zglfw");

const render = @import("renderer.zig");
const Renderer = render.Renderer;

pub fn main() !void {
    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);

    const window = try zglfw.Window.create(800, 600, "zig-gamedev playground", null, null);
    defer window.destroy();

    const allocator = std.heap.page_allocator;
    var renderer = try Renderer.init(allocator, window);
    defer renderer.deinit();

    while (!window.shouldClose()) {
        zglfw.pollEvents();

        if (!renderer.beginFrame(render.Color.white)) continue;
        defer renderer.endFrame();

        renderer.drawTriangle(.{
            .position = .{ .x = 0.0, .y = 0.0 },
            .size = .{ .x = 1.2, .y = 1.2 },
            .color = render.Color.black,
        });
    }
}
