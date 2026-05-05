const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");

const wgpu = zgpu.wgpu;

const monogram_font = @import("monogram_font.zig");

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

pub const FramebufferPixelSize = struct {
    width: u32,
    height: u32,
};

/// Position and size are framebuffer pixels, measured from the top-left.
pub const Rectangle = struct {
    position: Vec2,
    size: Vec2,
    color: Color = Color.black,
};

/// Position is framebuffer pixels, using raylib-style top-left text origin semantics.
pub const Text = struct {
    text: []const u8,
    position: Vec2,
    size: f32 = 24.0,
    color: Color = Color.black,
};

const Vertex = extern struct {
    position: [2]f32,
    color: [4]f32,
};

const TextVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

const rectangle_vertex_count = 6;
const max_rectangles_per_frame = 1024;
const text_vertex_count_per_glyph = 6;
const max_text_glyphs_per_frame = 4096;
const max_text_vertices_per_frame = text_vertex_count_per_glyph * max_text_glyphs_per_frame;
const text_line_spacing: f32 = 2.0;

pub const ZgpuRenderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    rectangle_pipeline: wgpu.RenderPipeline,
    bitmap_text_pipeline: wgpu.RenderPipeline,
    text_bind_group_layout: wgpu.BindGroupLayout,
    bitmap_text_bind_group: wgpu.BindGroup,
    rectangle_vertex_buffer: wgpu.Buffer,
    text_vertex_buffer: wgpu.Buffer,
    text_vertices: []TextVertex,
    bitmap_font: BitmapFont,
    bitmap_font_texture: wgpu.Texture,
    bitmap_font_texture_view: wgpu.TextureView,
    bitmap_font_sampler: wgpu.Sampler,
    rectangle_count: usize = 0,
    text_vertex_count: usize = 0,
    back_buffer_view: ?wgpu.TextureView = null,
    encoder: ?wgpu.CommandEncoder = null,
    pass: ?wgpu.RenderPassEncoder = null,

    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !ZgpuRenderer {
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
            .{
                .present_mode = .immediate
            },
        );
        errdefer gctx.destroy(allocator);

        const rectangle_pipeline = createRectanglePipeline(gctx);
        errdefer rectangle_pipeline.release();

        const bitmap_font = BitmapFont.init();

        var bitmap_font_texture_resources = try createBitmapFontTextureResources(allocator, gctx);
        errdefer bitmap_font_texture_resources.deinit();

        const text_bind_group_layout = createTextBindGroupLayout(gctx);
        errdefer text_bind_group_layout.release();

        const bitmap_text_bind_group = createTextBindGroup(gctx, text_bind_group_layout, bitmap_font_texture_resources.view, bitmap_font_texture_resources.sampler);
        errdefer bitmap_text_bind_group.release();

        const bitmap_text_pipeline = createBitmapTextPipeline(gctx, text_bind_group_layout);
        errdefer bitmap_text_pipeline.release();

        const rectangle_vertex_buffer = gctx.device.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @sizeOf(Vertex) * rectangle_vertex_count * max_rectangles_per_frame,
        });
        errdefer rectangle_vertex_buffer.release();

        const text_vertex_buffer = gctx.device.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @sizeOf(TextVertex) * max_text_vertices_per_frame,
        });
        errdefer text_vertex_buffer.release();

        const text_vertices = try allocator.alloc(TextVertex, max_text_vertices_per_frame);
        errdefer allocator.free(text_vertices);

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .rectangle_pipeline = rectangle_pipeline,
            .bitmap_text_pipeline = bitmap_text_pipeline,
            .text_bind_group_layout = text_bind_group_layout,
            .bitmap_text_bind_group = bitmap_text_bind_group,
            .rectangle_vertex_buffer = rectangle_vertex_buffer,
            .text_vertex_buffer = text_vertex_buffer,
            .text_vertices = text_vertices,
            .bitmap_font = bitmap_font,
            .bitmap_font_texture = bitmap_font_texture_resources.texture,
            .bitmap_font_texture_view = bitmap_font_texture_resources.view,
            .bitmap_font_sampler = bitmap_font_texture_resources.sampler,
        };
    }

    pub fn deinit(self: *ZgpuRenderer) void {
        self.allocator.free(self.text_vertices);
        self.bitmap_text_bind_group.release();
        self.bitmap_font_sampler.release();
        self.bitmap_font_texture_view.release();
        self.bitmap_font_texture.release();
        self.text_vertex_buffer.release();
        self.rectangle_vertex_buffer.release();
        self.bitmap_text_pipeline.release();
        self.text_bind_group_layout.release();
        self.rectangle_pipeline.release();
        self.gctx.destroy(self.allocator);
    }

    pub fn framebufferSize(self: *ZgpuRenderer) Vec2 {
        return .{
            .x = @floatFromInt(self.gctx.swapchain_descriptor.width),
            .y = @floatFromInt(self.gctx.swapchain_descriptor.height),
        };
    }

    pub fn framebufferPixelSize(self: *ZgpuRenderer) FramebufferPixelSize {
        return .{
            .width = self.gctx.swapchain_descriptor.width,
            .height = self.gctx.swapchain_descriptor.height,
        };
    }

    pub fn graphicsContext(self: *ZgpuRenderer) *zgpu.GraphicsContext {
        return self.gctx;
    }

    pub fn currentRenderPass(self: *ZgpuRenderer) wgpu.RenderPassEncoder {
        return self.pass.?;
    }

    pub fn beginFrame(self: *ZgpuRenderer, clear_color: Color) bool {
        if (!self.gctx.canRender()) return false;

        self.rectangle_count = 0;
        self.text_vertex_count = 0;

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

    pub fn endFrame(self: *ZgpuRenderer) void {
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

    pub fn drawRectangle(self: *ZgpuRenderer, rectangle: Rectangle) void {
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

    pub fn drawText(self: *ZgpuRenderer, text: Text) void {
        const view = std.unicode.Utf8View.init(text.text) catch return;
        const start_vertex = self.text_vertex_count;
        const framebuffer_size = self.framebufferSize();
        const color = colorComponents(text.color);
        const scale_factor = text.size / self.bitmap_font.base_size;
        const spacing = @trunc(scale_factor);

        var iterator = view.iterator();
        var text_offset_x: f32 = 0.0;
        var text_offset_y: f32 = 0.0;

        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint == '\n') {
                text_offset_y += text.size + text_line_spacing;
                text_offset_x = 0.0;
                continue;
            }

            const glyph = self.bitmap_font.glyph(codepoint) orelse self.bitmap_font.glyph('?').?;

            if ((codepoint != ' ') and (codepoint != '\t')) {
                std.debug.assert(self.text_vertex_count + text_vertex_count_per_glyph <= max_text_vertices_per_frame);
                appendGlyphVertices(
                    self.text_vertices[self.text_vertex_count..][0..text_vertex_count_per_glyph],
                    .{
                        .x = text.position.x + text_offset_x,
                        .y = text.position.y + text_offset_y,
                    },
                    .{
                        .x = glyph.width * scale_factor,
                        .y = glyph.height * scale_factor,
                    },
                    glyph.atlas_bounds,
                    self.bitmap_font.width,
                    self.bitmap_font.height,
                    framebuffer_size,
                    color,
                );
                self.text_vertex_count += text_vertex_count_per_glyph;
            }

            text_offset_x += glyph.width * scale_factor + spacing;
        }

        self.drawTextVertices(start_vertex, self.bitmap_text_pipeline, self.bitmap_text_bind_group);
    }

    fn drawTextVertices(self: *ZgpuRenderer, start_vertex: usize, pipeline: wgpu.RenderPipeline, bind_group: wgpu.BindGroup) void {
        const vertex_count = self.text_vertex_count - start_vertex;
        if (vertex_count == 0) return;

        const byte_offset = start_vertex * @sizeOf(TextVertex);
        const byte_count = vertex_count * @sizeOf(TextVertex);
        self.gctx.queue.writeBuffer(
            self.text_vertex_buffer,
            byte_offset,
            TextVertex,
            self.text_vertices[start_vertex..self.text_vertex_count],
        );

        const pass = self.pass.?;
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bind_group, null);
        pass.setVertexBuffer(0, self.text_vertex_buffer, @intCast(byte_offset), byte_count);
        pass.draw(@intCast(vertex_count), 1, 0, 0);
    }
};

const Bounds = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

const default_font_texture_width = monogram_font.texture_width;
const default_font_texture_height = monogram_font.texture_height;
const default_font_first_codepoint = monogram_font.first_codepoint;
const default_font_glyph_count = monogram_font.glyph_count;
const default_font_base_size = monogram_font.base_size;
const default_font_glyph_width = monogram_font.glyph_width;
const default_font_glyph_height = monogram_font.glyph_height;
const default_font_glyph_padding = monogram_font.glyph_padding;
const default_font_glyphs_per_row = monogram_font.glyphs_per_row;
const default_font_glyph_stride_x = monogram_font.glyph_stride_x;
const default_font_glyph_stride_y = monogram_font.glyph_stride_y;
const default_font_glyph_rows = monogram_font.glyph_rows;
const default_font_data = monogram_font.data;

const BitmapGlyph = struct {
    atlas_bounds: Bounds,
    width: f32,
    height: f32,
};

const BitmapFont = struct {
    glyphs: [default_font_glyph_count]BitmapGlyph,
    width: f32 = default_font_texture_width,
    height: f32 = default_font_texture_height,
    base_size: f32 = default_font_base_size,

    fn init() BitmapFont {
        var glyphs: [default_font_glyph_count]BitmapGlyph = undefined;

        for (&glyphs, 0..) |*glyph_out, glyph_index| {
            const x = default_font_glyph_padding + (glyph_index % default_font_glyphs_per_row) * default_font_glyph_stride_x;
            const y = default_font_glyph_padding + (glyph_index / default_font_glyphs_per_row) * default_font_glyph_stride_y;

            glyph_out.* = .{
                .atlas_bounds = .{
                    .left = @floatFromInt(x),
                    .top = @floatFromInt(y),
                    .right = @floatFromInt(x + default_font_glyph_width),
                    .bottom = @floatFromInt(y + default_font_glyph_height),
                },
                .width = default_font_glyph_width,
                .height = default_font_glyph_height,
            };
        }

        return .{ .glyphs = glyphs };
    }

    fn glyph(self: *const BitmapFont, codepoint: u21) ?BitmapGlyph {
        if (codepoint < default_font_first_codepoint) return null;
        const index = codepoint - default_font_first_codepoint;
        if (index >= default_font_glyph_count) return null;
        return self.glyphs[index];
    }
};

const FontTextureResources = struct {
    texture: wgpu.Texture,
    view: wgpu.TextureView,
    sampler: wgpu.Sampler,

    fn deinit(self: *FontTextureResources) void {
        self.sampler.release();
        self.view.release();
        self.texture.release();
    }
};

fn createBitmapFontTextureResources(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext) !FontTextureResources {
    const width = default_font_texture_width;
    const height = default_font_texture_height;
    const pixel_count: usize = width * height;
    std.debug.assert(default_font_data.len == default_font_glyph_count);
    std.debug.assert(default_font_data[0].len == default_font_glyph_height);
    std.debug.assert(default_font_glyph_padding + (default_font_glyphs_per_row - 1) * default_font_glyph_stride_x + default_font_glyph_width <= width);
    std.debug.assert(default_font_glyph_padding + (default_font_glyph_rows - 1) * default_font_glyph_stride_y + default_font_glyph_height <= height);

    const rgba_pixels = try allocator.alloc(u8, pixel_count * 4);
    defer allocator.free(rgba_pixels);
    @memset(rgba_pixels, 0);

    for (default_font_data, 0..) |glyph_rows, glyph_index| {
        const atlas_x = default_font_glyph_padding + (glyph_index % default_font_glyphs_per_row) * default_font_glyph_stride_x;
        const atlas_y = default_font_glyph_padding + (glyph_index / default_font_glyphs_per_row) * default_font_glyph_stride_y;

        for (glyph_rows, 0..) |bits, row| {
            for (0..default_font_glyph_width) |x| {
                const mask = @as(u8, 1) << @intCast(x);
                const pixel_index = (atlas_y + row) * width + atlas_x + x;
                const alpha: u8 = if ((bits & mask) != 0) 255 else 0;
                rgba_pixels[pixel_index * 4 + 0] = 255;
                rgba_pixels[pixel_index * 4 + 1] = 255;
                rgba_pixels[pixel_index * 4 + 2] = 255;
                rgba_pixels[pixel_index * 4 + 3] = alpha;
            }
        }
    }

    const texture = gctx.device.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .size = .{
            .width = width,
            .height = height,
            .depth_or_array_layers = 1,
        },
        .format = .rgba8_unorm,
    });
    errdefer texture.release();

    gctx.queue.writeTexture(
        .{ .texture = texture },
        .{
            .bytes_per_row = width * 4,
            .rows_per_image = height,
        },
        .{ .width = width, .height = height },
        u8,
        rgba_pixels,
    );

    const view = texture.createView(.{});
    errdefer view.release();

    const sampler = gctx.device.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
    });
    errdefer sampler.release();

    return .{
        .texture = texture,
        .view = view,
        .sampler = sampler,
    };
}

fn createTextBindGroupLayout(gctx: *zgpu.GraphicsContext) wgpu.BindGroupLayout {
    const entries = [_]wgpu.BindGroupLayoutEntry{
        zgpu.textureEntry(0, .{ .fragment = true }, .float, .tvdim_2d, false),
        zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
    };

    return gctx.device.createBindGroupLayout(.{
        .entry_count = entries.len,
        .entries = &entries,
    });
}

fn createTextBindGroup(
    gctx: *zgpu.GraphicsContext,
    layout: wgpu.BindGroupLayout,
    texture_view: wgpu.TextureView,
    sampler: wgpu.Sampler,
) wgpu.BindGroup {
    const entries = [_]wgpu.BindGroupEntry{
        .{ .binding = 0, .size = 0, .texture_view = texture_view },
        .{ .binding = 1, .size = 0, .sampler = sampler },
    };

    return gctx.device.createBindGroup(.{
        .layout = layout,
        .entry_count = entries.len,
        .entries = &entries,
    });
}

fn createBitmapTextPipeline(gctx: *zgpu.GraphicsContext, bind_group_layout: wgpu.BindGroupLayout) wgpu.RenderPipeline {
    const shader_module = zgpu.createWgslShaderModule(
        gctx.device,
        @embedFile("text_bitmap.wgsl"),
        "text-bitmap",
    );
    defer shader_module.release();

    const bind_group_layouts = [_]wgpu.BindGroupLayout{bind_group_layout};
    const pipeline_layout = gctx.device.createPipelineLayout(.{
        .bind_group_layout_count = bind_group_layouts.len,
        .bind_group_layouts = &bind_group_layouts,
    });
    defer pipeline_layout.release();

    const vertex_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = @offsetOf(TextVertex, "position"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(TextVertex, "uv"), .shader_location = 1 },
        .{ .format = .float32x4, .offset = @offsetOf(TextVertex, "color"), .shader_location = 2 },
    };
    const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
        .array_stride = @sizeOf(TextVertex),
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    }};

    const blend = wgpu.BlendState{
        .color = .{
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
        },
        .alpha = .{
            .src_factor = .one,
            .dst_factor = .one_minus_src_alpha,
        },
    };
    const color_targets = [_]wgpu.ColorTargetState{.{
        .format = zgpu.GraphicsContext.swapchain_format,
        .blend = &blend,
    }};

    return gctx.device.createRenderPipeline(.{
        .layout = pipeline_layout,
        .vertex = .{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = vertex_buffers.len,
            .buffers = &vertex_buffers,
        },
        .fragment = &.{
            .module = shader_module,
            .entry_point = "fs_main",
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
    });
}

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

fn appendGlyphVertices(
    vertices: []TextVertex,
    position: Vec2,
    size: Vec2,
    atlas_bounds: Bounds,
    atlas_width: f32,
    atlas_height: f32,
    framebuffer_size: Vec2,
    color: [4]f32,
) void {
    std.debug.assert(vertices.len == text_vertex_count_per_glyph);

    const left = position.x;
    const top = position.y;
    const right = position.x + size.x;
    const bottom = position.y + size.y;

    const uv_left = atlas_bounds.left / atlas_width;
    const uv_top = atlas_bounds.top / atlas_height;
    const uv_right = atlas_bounds.right / atlas_width;
    const uv_bottom = atlas_bounds.bottom / atlas_height;

    const positions = [_]Vec2{
        .{ .x = left, .y = top },
        .{ .x = left, .y = bottom },
        .{ .x = right, .y = top },
        .{ .x = right, .y = top },
        .{ .x = left, .y = bottom },
        .{ .x = right, .y = bottom },
    };
    const uvs = [_][2]f32{
        .{ uv_left, uv_top },
        .{ uv_left, uv_bottom },
        .{ uv_right, uv_top },
        .{ uv_right, uv_top },
        .{ uv_left, uv_bottom },
        .{ uv_right, uv_bottom },
    };

    for (vertices, positions, uvs) |*vertex, vertex_position, uv| {
        vertex.* = .{
            .position = screenToClip(vertex_position, framebuffer_size),
            .uv = uv,
            .color = color,
        };
    }
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

    const color = colorComponents(rectangle.color);

    var vertices: [rectangle_vertex_count]Vertex = undefined;
    for (&vertices, positions) |*vertex, position| {
        vertex.* = .{ .position = screenToClip(position, framebuffer_size), .color = color };
    }
    return vertices;
}

fn colorComponents(color: Color) [4]f32 {
    return .{
        @floatCast(color.r),
        @floatCast(color.g),
        @floatCast(color.b),
        @floatCast(color.a),
    };
}

fn screenToClip(position: Vec2, framebuffer_size: Vec2) [2]f32 {
    return .{
        position.x / framebuffer_size.x * 2.0 - 1.0,
        1.0 - position.y / framebuffer_size.y * 2.0,
    };
}
