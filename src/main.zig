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

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    const frame_allocator = frame_arena.allocator();

    while (!window.shouldClose()) {
        _ = frame_arena.reset(.retain_capacity);
        zglfw.pollEvents();
        const f10 = window.getKey(.F10);

        const mouse_pos_raw = window.getCursorPos();

        if (f10 == .press and previous_f10 == .release) {
            show_debug_ui = !show_debug_ui;
        }
        previous_f10 = f10;

        var frame = renderer.beginFrame(render.Color.white) orelse continue;
        defer frame.end();

        const pos_text = try std.fmt.allocPrint(frame_allocator, "{d}/{d}", .{mouse_pos_raw[0], mouse_pos_raw[1]});
        frame.drawText(.{
            .text = pos_text,
            .size = 48,
            .position = .{ .x = 600, .y = 600},
        });

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

                const text = try std.fmt.allocPrint(frame_allocator, "{d}/{d}", .{x + 1, y + 1});
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

