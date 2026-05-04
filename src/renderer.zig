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
    pub const red: Color = .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 };
    pub const green: Color = .{ .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 };
    pub const blue: Color = .{ .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 };

    fn toWgpu(self: Color) wgpu.Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
    }
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

/// Position and size are framebuffer pixels, measured from the top-left.
pub const Rectangle = struct {
    position: Vec2,
    size: Vec2,
    color: Color = Color.black,
};

const Vertex = extern struct {
    position: [2]f32,
    color: [4]f32,
};

const rectangle_vertex_count = 6;
const max_rectangles_per_frame = 1024;

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    rectangle_pipeline: wgpu.RenderPipeline,
    rectangle_vertex_buffer: wgpu.Buffer,
    rectangle_count: usize = 0,
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

        const rectangle_pipeline = createRectanglePipeline(gctx);
        errdefer rectangle_pipeline.release();

        const rectangle_vertex_buffer = gctx.device.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @sizeOf(Vertex) * rectangle_vertex_count * max_rectangles_per_frame,
        });
        errdefer rectangle_vertex_buffer.release();

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .rectangle_pipeline = rectangle_pipeline,
            .rectangle_vertex_buffer = rectangle_vertex_buffer,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.rectangle_vertex_buffer.release();
        self.rectangle_pipeline.release();
        self.gctx.destroy(self.allocator);
    }

    pub fn framebufferSize(self: *Renderer) Vec2 {
        return .{
            .x = @floatFromInt(self.gctx.swapchain_descriptor.width),
            .y = @floatFromInt(self.gctx.swapchain_descriptor.height),
        };
    }

    pub fn beginFrame(self: *Renderer, clear_color: Color) bool {
        if (!self.gctx.canRender()) return false;

        self.rectangle_count = 0;

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

    pub fn drawRectangle(self: *Renderer, rectangle: Rectangle) void {
        std.debug.assert(self.rectangle_count < max_rectangles_per_frame);

        const vertices = rectangleVertices(rectangle, self.framebufferSize());
        const vertex_offset = self.rectangle_count * rectangle_vertex_count;
        const byte_offset = vertex_offset * @sizeOf(Vertex);

        self.gctx.queue.writeBuffer(self.rectangle_vertex_buffer, byte_offset, Vertex, &vertices);

        const pass = self.pass.?;
        pass.setPipeline(self.rectangle_pipeline);
        pass.setVertexBuffer(0, self.rectangle_vertex_buffer, @intCast(byte_offset), @sizeOf(Vertex) * vertices.len);
        pass.draw(rectangle_vertex_count, 1, 0, 0);

        self.rectangle_count += 1;
    }
};

fn createRectanglePipeline(gctx: *zgpu.GraphicsContext) wgpu.RenderPipeline {
    const shader_module = zgpu.createWgslShaderModule(
        gctx.device,
        @embedFile("rectangle.wgsl"),
        "rectangle",
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

fn rectangleVertices(rectangle: Rectangle, framebuffer_size: Vec2) [rectangle_vertex_count]Vertex {
    const left = rectangle.position.x;
    const top = rectangle.position.y;
    const right = rectangle.position.x + rectangle.size.x;
    const bottom = rectangle.position.y + rectangle.size.y;

    const positions = [_]Vec2{
        .{ .x = left, .y = top },
        .{ .x = left, .y = bottom },
        .{ .x = right, .y = top },
        .{ .x = right, .y = top },
        .{ .x = left, .y = bottom },
        .{ .x = right, .y = bottom },
    };

    const color = [_]f32{
        @floatCast(rectangle.color.r),
        @floatCast(rectangle.color.g),
        @floatCast(rectangle.color.b),
        @floatCast(rectangle.color.a),
    };

    var vertices: [rectangle_vertex_count]Vertex = undefined;
    for (&vertices, positions) |*vertex, position| {
        vertex.* = .{ .position = screenToClip(position, framebuffer_size), .color = color };
    }
    return vertices;
}

fn screenToClip(position: Vec2, framebuffer_size: Vec2) [2]f32 {
    return .{
        position.x / framebuffer_size.x * 2.0 - 1.0,
        1.0 - position.y / framebuffer_size.y * 2.0,
    };
}
