const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");

const wgpu = zgpu.wgpu;

pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,

    pub const black: Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const white: Color = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };

    fn toWgpu(self: Color) wgpu.Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub const Triangle = struct {
    position: Vec2,
    size: Vec2 = .{ .x = 1.0, .y = 1.0 },
    rotation_radians: f32 = 0.0,
    color: Color = Color.black,
};

const Vertex = extern struct {
    position: [2]f32,
    color: [4]f32,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    triangle_pipeline: wgpu.RenderPipeline,
    triangle_vertex_buffer: wgpu.Buffer,
    back_buffer_view: ?wgpu.TextureView = null,
    encoder: ?wgpu.CommandEncoder = null,
    pass: ?wgpu.RenderPassEncoder = null,

    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !Renderer {
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

        const triangle_pipeline = createTrianglePipeline(gctx);
        errdefer triangle_pipeline.release();

        const triangle_vertex_buffer = gctx.device.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @sizeOf(Vertex) * 3,
        });
        errdefer triangle_vertex_buffer.release();

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .triangle_pipeline = triangle_pipeline,
            .triangle_vertex_buffer = triangle_vertex_buffer,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.triangle_vertex_buffer.release();
        self.triangle_pipeline.release();
        self.gctx.destroy(self.allocator);
    }

    pub fn beginFrame(self: *Renderer, clear_color: Color) bool {
        if (!self.gctx.canRender()) return false;

        const back_buffer_view = self.gctx.swapchain.getCurrentTextureView();
        const encoder = self.gctx.device.createCommandEncoder(null);

        self.back_buffer_view = back_buffer_view;
        self.encoder = encoder;
        self.pass = zgpu.beginRenderPassSimple(
            encoder,
            .clear,
            back_buffer_view,
            clear_color.toWgpu(),
            null,
            null,
        );

        return true;
    }

    pub fn endFrame(self: *Renderer) void {
        zgpu.endReleasePass(self.pass.?);

        const commands = self.encoder.?.finish(null);

        self.gctx.submit(&.{commands});
        _ = self.gctx.present();

        commands.release();
        self.encoder.?.release();
        self.back_buffer_view.?.release();

        self.pass = null;
        self.encoder = null;
        self.back_buffer_view = null;
    }

    pub fn drawTriangle(self: *Renderer, triangle: Triangle) void {
        const vertices = triangleVertices(triangle);

        self.gctx.queue.writeBuffer(self.triangle_vertex_buffer, 0, Vertex, &vertices);

        const pass = self.pass.?;
        pass.setPipeline(self.triangle_pipeline);
        pass.setVertexBuffer(0, self.triangle_vertex_buffer, 0, @sizeOf(Vertex) * vertices.len);
        pass.draw(3, 1, 0, 0);
    }
};

fn createTrianglePipeline(gctx: *zgpu.GraphicsContext) wgpu.RenderPipeline {
    const shader_module = zgpu.createWgslShaderModule(
        gctx.device,
        @embedFile("triangle.wgsl"),
        "triangle",
    );
    defer shader_module.release();

    const vertex_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "position"), .shader_location = 0 },
        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "color"), .shader_location = 1 },
    };
    const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
        .array_stride = @sizeOf(Vertex),
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    }};

    return gctx.device.createRenderPipeline(.{
        .vertex = .{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = vertex_buffers.len,
            .buffers = &vertex_buffers,
        },
        .fragment = &.{
            .module = shader_module,
            .entry_point = "fs_main",
            .target_count = 1,
            .targets = &.{.{ .format = zgpu.GraphicsContext.swapchain_format }},
        },
    });
}

fn triangleVertices(triangle: Triangle) [3]Vertex {
    const local_positions = [_]Vec2{
        .{ .x = 0.0, .y = 0.5 },
        .{ .x = -0.5, .y = -0.5 },
        .{ .x = 0.5, .y = -0.5 },
    };

    const color = [_]f32{
        @floatCast(triangle.color.r),
        @floatCast(triangle.color.g),
        @floatCast(triangle.color.b),
        @floatCast(triangle.color.a),
    };

    var vertices: [3]Vertex = undefined;
    for (&vertices, local_positions) |*vertex, position| {
        vertex.* = .{ .position = transformPoint(position, triangle), .color = color };
    }
    return vertices;
}

fn transformPoint(point: Vec2, triangle: Triangle) [2]f32 {
    const scaled = Vec2{
        .x = point.x * triangle.size.x,
        .y = point.y * triangle.size.y,
    };
    const rotation_sin = @sin(triangle.rotation_radians);
    const rotation_cos = @cos(triangle.rotation_radians);

    return .{
        scaled.x * rotation_cos - scaled.y * rotation_sin + triangle.position.x,
        scaled.x * rotation_sin + scaled.y * rotation_cos + triangle.position.y,
    };
}
