const zglfw = @import("zglfw");

const render = @import("renderer");

pub const Cursor = struct {
    position: render.Vec2,
    previous_position: render.Vec2,
    delta: render.Vec2,

    pub fn init(window: *zglfw.Window) Cursor {
        const position = windowCursorPosition(window);
        return .{
            .position = position,
            .previous_position = position,
            .delta = .{ .x = 0.0, .y = 0.0 },
        };
    }

    pub fn update(self: *Cursor, window: *zglfw.Window) void {
        const next_position = windowCursorPosition(window);

        self.previous_position = self.position;
        self.position = next_position;
        self.delta = .{
            .x = self.position.x - self.previous_position.x,
            .y = self.position.y - self.previous_position.y,
        };
    }
};

fn windowCursorPosition(window: *zglfw.Window) render.Vec2 {
    const position = window.getCursorPos();
    return .{
        .x = @floatCast(position[0]),
        .y = @floatCast(position[1]),
    };
}
