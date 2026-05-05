const std = @import("std");

const zglfw = @import("zglfw");
const zgui = @import("zgui");

pub const FrameStats = struct {
    fps: f64,
    average_cpu_time_ms: f64,
    screen_width: u32,
    screen_height: u32,
};

pub const DebugUi = struct {
    previous_time: f64 = 0.0,
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
            .previous_time = now,
            .fps_refresh_time = now,
        };
    }

    pub fn deinit(self: *DebugUi, renderer: anytype) void {
        _ = self;
        renderer.deinitDebugUi();
        zgui.deinit();
    }

    pub fn draw(self: *DebugUi, renderer: anytype, framebuffer_size: anytype) void {
        self.tick(zglfw.getTime());

        renderer.beginDebugUi(framebuffer_size.width, framebuffer_size.height);
        drawStatsWindow(.{
            .fps = self.fps,
            .average_cpu_time_ms = self.average_cpu_time_ms,
            .screen_width = framebuffer_size.width,
            .screen_height = framebuffer_size.height,
        });
        renderer.endDebugUi();
    }

    fn tick(self: *DebugUi, now_secs: f64) void {
        self.previous_time = now_secs;

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
    }
    zgui.end();
}
