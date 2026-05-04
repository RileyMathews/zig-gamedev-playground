const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

const window_title = "zig-gamedev playground";

// zig fmt: off
const triangle_wgsl =
\\struct VertexOut {
\\    @builtin(position) position: vec4<f32>,
\\    @location(0) color: vec3<f32>,
\\}
\\
\\@vertex fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOut {
\\    let positions = array<vec2<f32>, 3>(
\\        vec2<f32>(0.0, 0.6),
\\        vec2<f32>(-0.6, -0.6),
\\        vec2<f32>(0.6, -0.6),
\\    );
\\    let colors = array<vec3<f32>, 3>(
\\        vec3<f32>(1.0, 0.2, 0.2),
\\        vec3<f32>(0.2, 1.0, 0.2),
\\        vec3<f32>(0.2, 0.4, 1.0),
\\    );
\\
\\    var out: VertexOut;
\\    out.position = vec4<f32>(positions[vertex_index], 0.0, 1.0);
\\    out.color = colors[vertex_index];
\\    return out;
\\}
\\
\\@fragment fn fs_main(@location(0) color: vec3<f32>) -> @location(0) vec4<f32> {
\\    return vec4<f32>(color, 1.0);
\\}
;
// zig fmt: on

const App = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    pipeline: zgpu.RenderPipelineHandle,

    fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !App {
        const gctx = try zgpu.GraphicsContext.create(
            allocator,
            .{
                .window = window,
                .fn_getTime = @ptrCast(&zglfw.getTime),
                .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
                .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
                .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
                .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
                .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
                .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
                .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
            },
            .{},
        );
        errdefer gctx.destroy(allocator);

        const shader_module = zgpu.createWgslShaderModule(gctx.device, triangle_wgsl, "triangle");
        defer shader_module.release();

        const pipeline_layout = gctx.createPipelineLayout(&.{});
        defer gctx.releaseResource(pipeline_layout);

        const color_targets = [_]wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
        }};

        const pipeline = gctx.createRenderPipeline(pipeline_layout, .{
            .vertex = .{
                .module = shader_module,
                .entry_point = "vs_main",
            },
            .primitive = .{
                .topology = .triangle_list,
                .front_face = .ccw,
                .cull_mode = .none,
            },
            .fragment = &.{
                .module = shader_module,
                .entry_point = "fs_main",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
        });

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .pipeline = pipeline,
        };
    }

    fn deinit(app: *App) void {
        app.gctx.destroy(app.allocator);
        app.* = undefined;
    }

    fn draw(app: *App) void {
        const gctx = app.gctx;
        if (!gctx.canRender()) return;

        const back_buffer_view = gctx.swapchain.getCurrentTextureView();
        defer back_buffer_view.release();

        const commands = commands: {
            const encoder = gctx.device.createCommandEncoder(null);
            defer encoder.release();

            {
                const pass = zgpu.beginRenderPassSimple(
                    encoder,
                    .clear,
                    back_buffer_view,
                    .{ .r = 0.02, .g = 0.02, .b = 0.03, .a = 1.0 },
                    null,
                    null,
                );
                defer zgpu.endReleasePass(pass);

                if (gctx.lookupResource(app.pipeline)) |pipeline| {
                    pass.setPipeline(pipeline);
                    pass.draw(3, 1, 0, 0);
                }
            }

            break :commands encoder.finish(null);
        };
        defer commands.release();

        gctx.submit(&.{commands});
        _ = gctx.present();
    }
};

pub fn main() !void {
    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    const window = try zglfw.Window.create(800, 600, window_title, null, null);
    defer window.destroy();
    window.setSizeLimits(320, 240, -1, -1);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try App.init(gpa.allocator(), window);
    defer app.deinit();

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        app.draw();
    }
}
