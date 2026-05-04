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

        const screen = renderer.framebufferSize();
        renderer.drawRectangle(.{
            .position = .{ .x = 0, .y = 0 },
            .size = .{ .x = screen.x * 0.5, .y = screen.y * 0.05 },
            .color = render.Color.black,
        });
        renderer.drawRectangle(.{
            .position = .{ .x = screen.x * 0.5, .y = 0 },
            .size = .{ .x = screen.x * 0.5, .y = screen.y * 0.5 },
            .color = render.Color.blue,
        });
        renderer.drawText(.{
            .text = "MSDF text rendering",
            .position = .{ .x = 24, .y = 24 },
            .size = 32,
            .color = render.Color.red,
        });
    }
}
