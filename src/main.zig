const std = @import("std");
const zglfw = @import("zglfw");

const debug_ui = @import("debug_ui.zig");
const render = @import("renderers/zgpu/renderer.zig");
const ZgpuRenderer = render.ZgpuRenderer;

pub fn main() !void {
    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);

    const window = try zglfw.Window.create(800, 600, "zig-gamedev playground", null, null);
    defer window.destroy();

    const allocator = std.heap.page_allocator;
    var renderer = try ZgpuRenderer.init(allocator, window);
    defer renderer.deinit();

    var debug_ui_state = debug_ui.DebugUi.init(allocator, window, renderer.graphicsContext());
    defer debug_ui_state.deinit();

    var glyph_demo_buffer: [512]u8 = undefined;
    const glyph_demo_text = buildGlyphDemoText(glyph_demo_buffer[0..]);

    while (!window.shouldClose()) {
        zglfw.pollEvents();

        if (!renderer.beginFrame(render.Color.white)) continue;
        defer renderer.endFrame();

        renderer.drawText(.{
            .text = glyph_demo_text,
            .position = .{ .x = 0, .y = 0 },
            .size = 48,
            .color = render.Color.black,
        });

        renderer.drawRectangle(.{
            .position = .{ .x = 0, .y = 48 },
            .size = .{ .x = 48, .y = 48 },
            .color = render.Color.blue,
        });

        const framebuffer_size = renderer.framebufferPixelSize();
        const gctx = renderer.graphicsContext();
        debug_ui_state.draw(renderer.currentRenderPass(), .{
            .fps = gctx.stats.fps,
            .average_cpu_time_ms = gctx.stats.average_cpu_time,
            .screen_width = framebuffer_size.width,
            .screen_height = framebuffer_size.height,
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
