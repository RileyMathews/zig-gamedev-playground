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

    var glyph_demo_buffer: [512]u8 = undefined;
    const glyph_demo_text = buildGlyphDemoText(glyph_demo_buffer[0..]);

    while (!window.shouldClose()) {
        zglfw.pollEvents();

        if (!renderer.beginFrame(render.Color.white)) continue;
        defer renderer.endFrame();

        renderer.drawText(.{
            .text = glyph_demo_text,
            .position = .{ .x = 0, .y = 0 },
            .size = 24,
            .color = render.Color.black,
        });
    }
}

fn buildGlyphDemoText(buffer: []u8) []const u8 {
    var len: usize = 0;

    for (32..256) |value| {
        const codepoint: u21 = @intCast(value);
        len += std.unicode.utf8Encode(codepoint, buffer[len..]) catch unreachable;
    }

    return buffer[0..len];
}
