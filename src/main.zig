const std = @import("std");
const zglfw = @import("zglfw");

const debug_ui = @import("debug_ui.zig");
const render = @import("renderer");
const Renderer = render.Renderer;

const world_width = 8;
const world_height = 8;
const tile_size = 64;
const tile_text_size = 24;

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

    var show_debug_ui = false;
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

        for (0..world_height) |y| {
            for (0..world_width) |x| {
                const tileRect: render.Rectangle = .{
                    .size = .{ .x = tile_size, .y = tile_size},
                    .position = .{ .x = @floatFromInt(x * tile_size), .y = @floatFromInt(y * tile_size)},
                };
                frame.drawRectangle(.{
                    .rectangle = tileRect,
                    .color = if (@mod(y * world_width + x, 2) == 1) render.Color.red else render.Color.blue,
                });

                var text_buf: [8]u8 = undefined;
                const text = try std.fmt.bufPrint(&text_buf, "{d}/{d}", .{x + 1, y + 1});

                const textSize = render.measureText(text, tile_text_size);

                frame.drawText(.{
                    .text = text,
                    .size = tile_text_size,
                    .position = tileRect.centeredPosition(textSize)
                });
            }
        }

        if (show_debug_ui) {
            debug_ui_state.draw(&frame, renderer.framebufferPixelSize());
        }
    }
}

