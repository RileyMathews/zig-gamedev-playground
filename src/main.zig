const std = @import("std");
const zglfw = @import("zglfw");

const cursor_input = @import("cursor.zig");
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

const TrackedKey = struct {
    key: zglfw.Key,
    last_frame_state: zglfw.Action,

    pub fn track(key: zglfw.Key) TrackedKey {
        return .{ .key = key, .last_frame_state = .release };
    }

    pub fn isPressed(self: *TrackedKey, window: *zglfw.Window) bool {
        var is_pressed = false;
        const current_frame_state =  window.getKey(self.key);
        if (current_frame_state == .press and self.last_frame_state == .release) {
            is_pressed = true;
        }
        self.last_frame_state = current_frame_state;
        return is_pressed;
    }
};

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
    var f10_key = TrackedKey.track(.F10);

    var show_roster_menu = false;
    var r_key = TrackedKey.track(.r);

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    const frame_allocator = frame_arena.allocator();

    var cursor = cursor_input.Cursor.init(window);
    var roster_menu_rectangle: render.Rectangle = .{
        .position = .{ .x = 0, .y = 0 },
        .size = .{ .x = 300, .y = 900 },
    };

    while (!window.shouldClose()) {
        _ = frame_arena.reset(.retain_capacity);

        zglfw.pollEvents();
        cursor.update(window);

        if (f10_key.isPressed(window)) {
            show_debug_ui = !show_debug_ui;
        }

        if (r_key.isPressed(window)) {
            show_roster_menu = !show_roster_menu;
        }
        const hover_tile = tileAtPosition(cursor.position);

        var frame = renderer.beginFrame(render.Color.white) orelse continue;
        defer frame.end();

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

        if (show_roster_menu) {
            if (window.getMouseButton(.left) == .press and roster_menu_rectangle.contains(cursor.position)) {
                roster_menu_rectangle.position.x += cursor.delta.x;
                roster_menu_rectangle.position.y += cursor.delta.y;
            }

            frame.drawRectangle(.{
                .rectangle = roster_menu_rectangle,
                .color = render.Color.black,
            });
        }

        if (show_debug_ui) {
            debug_ui_state.draw(&frame, renderer.framebufferPixelSize(), cursor.position, hover_tile);
        }
    }
}
