const std = @import("std");
const zglfw = @import("zglfw");

const debug_ui = @import("debug_ui.zig");
const render = @import("renderer");
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

    var debug_ui_state = try debug_ui.DebugUi.init(allocator, window, &renderer);
    defer debug_ui_state.deinit(&renderer);

    const tiles: [8]i32 = [8]i32{0, 1, 2, 3, 4, 5, 6, 7};

    var show_debug_ui = true;
    var previous_f10 = zglfw.Action.release;

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        const f10 = window.getKey(.F10);

        if (f10 == .press and previous_f10 == .release) {
            show_debug_ui = !show_debug_ui;
        }
        previous_f10 = f10;

        var frame = renderer.beginFrame(render.Color.white) orelse continue;
        defer frame.end();

        for (tiles) |index| {
            const tileRect: render.Rectangle = .{
                .size = .{ .x = 48, .y = 48},
                .position = .{ .x = @floatFromInt(index * 48), .y = 0},
            };
            frame.drawRectangle(.{
                .rectangle = tileRect,
                .color = if (@mod(index, 2) == 1) render.Color.red else render.Color.blue,
            });

            var text_buf: [8]u8 = undefined;
            const text = try std.fmt.bufPrint(&text_buf, "{d}", .{index});

            const textSize = render.measureText(text, 42);

            frame.drawText(.{
                .text = text,
                .size = 42,
                .position = tileRect.centeredPosition(textSize)
            });
        }

        if (show_debug_ui) {
            debug_ui_state.draw(&frame, renderer.framebufferPixelSize());
        }
    }
}

