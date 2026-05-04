const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");

const wgpu = zgpu.wgpu;

const ui_font_json = @embedFile("ui_font_json");
const ui_font_bin = @embedFile("ui_font_bin");

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

/// Position is framebuffer pixels, measured from the top-left of the line box.
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

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    rectangle_pipeline: wgpu.RenderPipeline,
    text_pipeline: wgpu.RenderPipeline,
    text_bind_group_layout: wgpu.BindGroupLayout,
    text_bind_group: wgpu.BindGroup,
    rectangle_vertex_buffer: wgpu.Buffer,
    text_vertex_buffer: wgpu.Buffer,
    text_vertices: []TextVertex,
    font_atlas: FontAtlas,
    font_texture: wgpu.Texture,
    font_texture_view: wgpu.TextureView,
    font_sampler: wgpu.Sampler,
    rectangle_count: usize = 0,
    text_vertex_count: usize = 0,
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

        var font_atlas = try FontAtlas.init(allocator);
        errdefer font_atlas.deinit();

        var font_texture_resources = try createFontTextureResources(allocator, gctx, &font_atlas);
        errdefer font_texture_resources.deinit();

        const text_bind_group_layout = createTextBindGroupLayout(gctx);
        errdefer text_bind_group_layout.release();

        const text_bind_group = createTextBindGroup(gctx, text_bind_group_layout, font_texture_resources.view, font_texture_resources.sampler);
        errdefer text_bind_group.release();

        const text_pipeline = createTextPipeline(gctx, text_bind_group_layout);
        errdefer text_pipeline.release();

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
            .text_pipeline = text_pipeline,
            .text_bind_group_layout = text_bind_group_layout,
            .text_bind_group = text_bind_group,
            .rectangle_vertex_buffer = rectangle_vertex_buffer,
            .text_vertex_buffer = text_vertex_buffer,
            .text_vertices = text_vertices,
            .font_atlas = font_atlas,
            .font_texture = font_texture_resources.texture,
            .font_texture_view = font_texture_resources.view,
            .font_sampler = font_texture_resources.sampler,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.text_vertices);
        self.text_bind_group.release();
        self.font_sampler.release();
        self.font_texture_view.release();
        self.font_texture.release();
        self.font_atlas.deinit();
        self.text_vertex_buffer.release();
        self.rectangle_vertex_buffer.release();
        self.text_pipeline.release();
        self.text_bind_group_layout.release();
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

    pub fn drawText(self: *Renderer, text: Text) void {
        const view = std.unicode.Utf8View.init(text.text) catch return;
        const start_vertex = self.text_vertex_count;
        const framebuffer_size = self.framebufferSize();
        const color = colorComponents(text.color);

        var iterator = view.iterator();
        var cursor_x = text.position.x;
        var line_top = text.position.y;
        var baseline_y = line_top - self.font_atlas.ascender * text.size;
        var previous_codepoint: ?u21 = null;

        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint == '\n') {
                cursor_x = text.position.x;
                line_top += self.font_atlas.line_height * text.size;
                baseline_y = line_top - self.font_atlas.ascender * text.size;
                previous_codepoint = null;
                continue;
            }

            const glyph = self.font_atlas.glyph(codepoint) orelse self.font_atlas.glyph('?') orelse continue;

            if (previous_codepoint) |previous| {
                cursor_x += self.font_atlas.kerning(previous, codepoint) * text.size;
            }

            if (glyph.plane_bounds) |plane_bounds| {
                if (glyph.atlas_bounds) |atlas_bounds| {
                    std.debug.assert(self.text_vertex_count + text_vertex_count_per_glyph <= max_text_vertices_per_frame);
                    appendGlyphVertices(
                        self.text_vertices[self.text_vertex_count..][0..text_vertex_count_per_glyph],
                        cursor_x,
                        baseline_y,
                        text.size,
                        plane_bounds,
                        atlas_bounds,
                        self.font_atlas.width,
                        self.font_atlas.height,
                        framebuffer_size,
                        color,
                    );
                    self.text_vertex_count += text_vertex_count_per_glyph;
                }
            }

            cursor_x += glyph.advance * text.size;
            previous_codepoint = codepoint;
        }

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
        pass.setPipeline(self.text_pipeline);
        pass.setBindGroup(0, self.text_bind_group, null);
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

const Glyph = struct {
    advance: f32,
    plane_bounds: ?Bounds,
    atlas_bounds: ?Bounds,
};

const FontAtlas = struct {
    glyphs: std.AutoHashMap(u21, Glyph),
    kerning_pairs: std.AutoHashMap(u64, f32),
    width: f32,
    height: f32,
    ascender: f32,
    line_height: f32,

    fn init(allocator: std.mem.Allocator) !FontAtlas {
        const parsed = try std.json.parseFromSlice(FontJson, allocator, ui_font_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var glyphs = std.AutoHashMap(u21, Glyph).init(allocator);
        errdefer glyphs.deinit();

        for (parsed.value.glyphs) |json_glyph| {
            const unicode = json_glyph.unicode orelse continue;
            try glyphs.put(@intCast(unicode), .{
                .advance = json_glyph.advance,
                .plane_bounds = if (json_glyph.planeBounds) |bounds| bounds.toBounds() else null,
                .atlas_bounds = if (json_glyph.atlasBounds) |bounds| bounds.toBounds() else null,
            });
        }

        var kerning_pairs = std.AutoHashMap(u64, f32).init(allocator);
        errdefer kerning_pairs.deinit();

        if (parsed.value.kerning) |json_kerning_pairs| {
            for (json_kerning_pairs) |json_kerning| {
                const unicode1 = json_kerning.unicode1 orelse continue;
                const unicode2 = json_kerning.unicode2 orelse continue;
                try kerning_pairs.put(kerningKey(@intCast(unicode1), @intCast(unicode2)), json_kerning.advance);
            }
        }

        return .{
            .glyphs = glyphs,
            .kerning_pairs = kerning_pairs,
            .width = parsed.value.atlas.width,
            .height = parsed.value.atlas.height,
            .ascender = parsed.value.metrics.ascender,
            .line_height = parsed.value.metrics.lineHeight,
        };
    }

    fn deinit(self: *FontAtlas) void {
        self.kerning_pairs.deinit();
        self.glyphs.deinit();
    }

    fn glyph(self: *const FontAtlas, codepoint: u21) ?Glyph {
        return self.glyphs.get(codepoint);
    }

    fn kerning(self: *const FontAtlas, left: u21, right: u21) f32 {
        return self.kerning_pairs.get(kerningKey(left, right)) orelse 0.0;
    }
};

const FontJson = struct {
    atlas: struct {
        width: f32,
        height: f32,
    },
    metrics: struct {
        ascender: f32,
        lineHeight: f32,
    },
    glyphs: []const GlyphJson,
    kerning: ?[]const KerningJson = null,
};

const GlyphJson = struct {
    unicode: ?u32 = null,
    advance: f32,
    planeBounds: ?BoundsJson = null,
    atlasBounds: ?BoundsJson = null,
};

const KerningJson = struct {
    unicode1: ?u32 = null,
    unicode2: ?u32 = null,
    advance: f32,
};

const BoundsJson = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    fn toBounds(self: BoundsJson) Bounds {
        return .{
            .left = self.left,
            .top = self.top,
            .right = self.right,
            .bottom = self.bottom,
        };
    }
};

fn kerningKey(left: u21, right: u21) u64 {
    return (@as(u64, left) << 32) | @as(u64, right);
}

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

fn createFontTextureResources(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, font_atlas: *const FontAtlas) !FontTextureResources {
    const width: u32 = @intFromFloat(font_atlas.width);
    const height: u32 = @intFromFloat(font_atlas.height);
    const pixel_count: usize = @as(usize, width) * @as(usize, height);
    std.debug.assert(ui_font_bin.len == pixel_count * 3);

    const rgba_pixels = try allocator.alloc(u8, pixel_count * 4);
    defer allocator.free(rgba_pixels);
    for (0..pixel_count) |pixel_index| {
        rgba_pixels[pixel_index * 4 + 0] = ui_font_bin[pixel_index * 3 + 0];
        rgba_pixels[pixel_index * 4 + 1] = ui_font_bin[pixel_index * 3 + 1];
        rgba_pixels[pixel_index * 4 + 2] = ui_font_bin[pixel_index * 3 + 2];
        rgba_pixels[pixel_index * 4 + 3] = 255;
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
        .mag_filter = .linear,
        .min_filter = .linear,
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

fn createTextPipeline(gctx: *zgpu.GraphicsContext, bind_group_layout: wgpu.BindGroupLayout) wgpu.RenderPipeline {
    const shader_module = zgpu.createWgslShaderModule(
        gctx.device,
        @embedFile("text_msdf.wgsl"),
        "text-msdf",
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
    cursor_x: f32,
    baseline_y: f32,
    size: f32,
    plane_bounds: Bounds,
    atlas_bounds: Bounds,
    atlas_width: f32,
    atlas_height: f32,
    framebuffer_size: Vec2,
    color: [4]f32,
) void {
    std.debug.assert(vertices.len == text_vertex_count_per_glyph);

    const left = cursor_x + plane_bounds.left * size;
    const top = baseline_y + plane_bounds.top * size;
    const right = cursor_x + plane_bounds.right * size;
    const bottom = baseline_y + plane_bounds.bottom * size;

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

    for (vertices, positions, uvs) |*vertex, position, uv| {
        vertex.* = .{
            .position = screenToClip(position, framebuffer_size),
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
