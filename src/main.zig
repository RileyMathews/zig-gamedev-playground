const std = @import("std");
const zglfw = @import("zglfw");
const ztracy = @import("ztracy");

const debug_ui = @import("debug_ui.zig");
const render = @import("renderer");
const Renderer = render.Renderer;

const world_width = 10;
const world_height = 10;
const tile_size = 64;
const tile_text_size = 16;

const TileCoord = struct {
    x: usize,
    y: usize,
};

fn tileAtPosition(position: render.Vec2) ?TileCoord {
    if (position.x < 0.0 or position.y < 0.0) return null;

    const tile_size_float: f32 = @floatFromInt(tile_size);
    const tile_x: usize = @intFromFloat(@floor(position.x / tile_size_float));
    const tile_y: usize = @intFromFloat(@floor(position.y / tile_size_float));

    if (tile_x >= world_width or tile_y >= world_height) return null;

    return .{ .x = tile_x, .y = tile_y };
}

pub fn main() !void {
    ztracy.SetThreadName("main");

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
        const frame_zone = ztracy.ZoneN(@src(), "Frame");
        defer ztracy.FrameMark();
        defer frame_zone.End();

        {
            const tracy_zone = ztracy.ZoneN(@src(), "Reset Frame Arena");
            defer tracy_zone.End();
            _ = frame_arena.reset(.retain_capacity);
        }

        {
            const tracy_zone = ztracy.ZoneN(@src(), "Poll Events");
            defer tracy_zone.End();
            zglfw.pollEvents();
        }

        const f10 = window.getKey(.F10);
        const mouse_pos_raw = window.getCursorPos();
        const hover_tile = blk: {
            const tracy_zone = ztracy.ZoneN(@src(), "Update Input");
            defer tracy_zone.End();

            const mouse_pos: render.Vec2 = .{
                .x = @floatCast(mouse_pos_raw[0]),
                .y = @floatCast(mouse_pos_raw[1]),
            };

            if (f10 == .press and previous_f10 == .release) {
                show_debug_ui = !show_debug_ui;
            }
            previous_f10 = f10;

            break :blk tileAtPosition(mouse_pos);
        };

        const begin_frame_zone = ztracy.ZoneN(@src(), "Begin Frame");
        var frame = renderer.beginFrame(render.Color.white) orelse {
            begin_frame_zone.End();
            continue;
        };
        begin_frame_zone.End();
        defer {
            const tracy_zone = ztracy.ZoneN(@src(), "End Frame");
            defer tracy_zone.End();
            frame.end();
        }

        {
            const tracy_zone = ztracy.ZoneN(@src(), "Draw World");
            defer tracy_zone.End();

            for (0..world_height) |y| {
                for (0..world_width) |x| {
                    const tile_rect: render.Rectangle = .{
                        .size = .{ .x = tile_size, .y = tile_size },
                        .position = .{ .x = @floatFromInt(x * tile_size), .y = @floatFromInt(y * tile_size) },
                    };
                    const is_hovered = if (hover_tile) |tile| tile.x == x and tile.y == y else false;

                    frame.drawRectangle(.{
                        .rectangle = tile_rect,
                        .color = if (is_hovered) render.Color.green else render.Color.brown,
                    });

                    if (show_debug_ui) {
                        const text = try std.fmt.allocPrint(frame_allocator, "{d}/{d}", .{ x, y });
                        const textSize = render.measureText(text, tile_text_size);

                        frame.drawText(.{
                            .text = text,
                            .size = tile_text_size,
                            .position = tile_rect.centeredPosition(textSize),
                            .color = render.Color.pink,
                        });
                    }
                }
            }
        }

        if (show_debug_ui) {
            const tracy_zone = ztracy.ZoneN(@src(), "Draw Debug UI");
            defer tracy_zone.End();
            debug_ui_state.draw(&frame, renderer.framebufferPixelSize(), mouse_pos_raw, hover_tile);
        }
    }
}
