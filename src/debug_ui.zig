const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zgui = @import("zgui");

const wgpu = zgpu.wgpu;

pub const FrameStats = struct {
    fps: f64,
    average_cpu_time_ms: f64,
    screen_width: u32,
    screen_height: u32,
};

pub const DebugUi = struct {
    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window, gctx: *zgpu.GraphicsContext) DebugUi {
        zgui.init(allocator);
        zgui.io.setIniFilename(null);

        zgui.backend.init(
            window,
            gctx.device,
            @intFromEnum(zgpu.GraphicsContext.swapchain_format),
            @intFromEnum(wgpu.TextureFormat.undef),
        );

        const content_scale = window.getContentScale();
        zgui.getStyle().scaleAllSizes(@max(content_scale[0], content_scale[1]));

        return .{};
    }

    pub fn deinit(self: *DebugUi) void {
        _ = self;
        zgui.backend.deinit();
        zgui.deinit();
    }

    pub fn draw(self: *DebugUi, pass: wgpu.RenderPassEncoder, stats: FrameStats) void {
        _ = self;

        zgui.backend.newFrame(stats.screen_width, stats.screen_height);
        drawStatsWindow(stats);
        zgui.backend.draw(pass);
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
