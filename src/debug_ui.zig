const std = @import("std");

const zglfw = @import("zglfw");
const zgui = @import("zgui");

const render = @import("renderer");

pub const FrameStats = struct {
    fps: f64,
    average_cpu_time_ms: f64,
    screen_width: u32,
    screen_height: u32,
    mouse_x: f32,
    mouse_y: f32,
    tile_x: ?usize,
    tile_y: ?usize,
};

pub const DebugUi = struct {
    fps_refresh_time: f64 = 0.0,
    fps_counter: u32 = 0,
    fps: f64 = 0.0,
    average_cpu_time_ms: f64 = 0.0,

    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window, renderer: anytype) !DebugUi {
        zgui.init(allocator);
        errdefer zgui.deinit();

        zgui.io.setIniFilename(null);
        try renderer.initDebugUi(window);

        const content_scale = window.getContentScale();
        zgui.getStyle().scaleAllSizes(@max(content_scale[0], content_scale[1]));

        const now = zglfw.getTime();
        return .{
            .fps_refresh_time = now,
        };
    }

    pub fn deinit(self: *DebugUi, renderer: anytype) void {
        _ = self;
        renderer.deinitDebugUi();
        zgui.deinit();
    }

    pub fn draw(self: *DebugUi, frame: anytype, framebuffer_size: anytype, mouse_pos: render.Vec2, hover_tile: anytype) void {
        self.tick(zglfw.getTime());

        frame.beginDebugUi(framebuffer_size.width, framebuffer_size.height);
        drawStatsWindow(.{
            .fps = self.fps,
            .average_cpu_time_ms = self.average_cpu_time_ms,
            .screen_width = framebuffer_size.width,
            .screen_height = framebuffer_size.height,
            .mouse_x = mouse_pos.x,
            .mouse_y = mouse_pos.y,
            .tile_x = if (hover_tile) |tile| tile.x else null,
            .tile_y = if (hover_tile) |tile| tile.y else null,
        });
        frame.endDebugUi();
    }

    fn tick(self: *DebugUi, now_secs: f64) void {
        if ((now_secs - self.fps_refresh_time) >= 1.0) {
            const elapsed = now_secs - self.fps_refresh_time;
            self.fps = @as(f64, @floatFromInt(self.fps_counter)) / elapsed;
            self.average_cpu_time_ms = if (self.fps > 0.0) (1.0 / self.fps) * 1000.0 else 0.0;
            self.fps_refresh_time = now_secs;
            self.fps_counter = 0;
        }

        self.fps_counter += 1;
    }
};

fn drawStatsWindow(stats: FrameStats) void {
    zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 260.0, .h = 0.0, .cond = .first_use_ever });

    if (zgui.begin("Debug", .{ .flags = .{ .always_auto_resize = true, .no_saved_settings = true } })) {
        zgui.text("FPS: {d:.1}", .{stats.fps});
        zgui.text("Frame time: {d:.3} ms", .{stats.average_cpu_time_ms});
        zgui.separator();
        zgui.text("Screen: {d} x {d}", .{ stats.screen_width, stats.screen_height });
        zgui.text("Mouse: {d:.1}, {d:.1}", .{ stats.mouse_x, stats.mouse_y });
        if (stats.tile_x) |tile_x| {
            zgui.text("Tile: {d}, {d}", .{ tile_x, stats.tile_y.? });
        } else {
            zgui.text("Tile: none", .{});
        }
    }
    zgui.end();
}
