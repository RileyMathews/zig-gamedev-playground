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

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    rectangle_pipeline: wgpu.RenderPipeline,
    bitmap_text_pipeline: wgpu.RenderPipeline,
    text_pipeline: wgpu.RenderPipeline,
    text_bind_group_layout: wgpu.BindGroupLayout,
    bitmap_text_bind_group: wgpu.BindGroup,
    text_bind_group: wgpu.BindGroup,
    rectangle_vertex_buffer: wgpu.Buffer,
    text_vertex_buffer: wgpu.Buffer,
    text_vertices: []TextVertex,
    bitmap_font: BitmapFont,
    bitmap_font_texture: wgpu.Texture,
    bitmap_font_texture_view: wgpu.TextureView,
    bitmap_font_sampler: wgpu.Sampler,
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

        const bitmap_font = BitmapFont.init();

        var bitmap_font_texture_resources = try createBitmapFontTextureResources(allocator, gctx);
        errdefer bitmap_font_texture_resources.deinit();

        const text_bind_group_layout = createTextBindGroupLayout(gctx);
        errdefer text_bind_group_layout.release();

        const text_bind_group = createTextBindGroup(gctx, text_bind_group_layout, font_texture_resources.view, font_texture_resources.sampler);
        errdefer text_bind_group.release();

        const bitmap_text_bind_group = createTextBindGroup(gctx, text_bind_group_layout, bitmap_font_texture_resources.view, bitmap_font_texture_resources.sampler);
        errdefer bitmap_text_bind_group.release();

        const bitmap_text_pipeline = createBitmapTextPipeline(gctx, text_bind_group_layout);
        errdefer bitmap_text_pipeline.release();

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
            .bitmap_text_pipeline = bitmap_text_pipeline,
            .text_pipeline = text_pipeline,
            .text_bind_group_layout = text_bind_group_layout,
            .bitmap_text_bind_group = bitmap_text_bind_group,
            .text_bind_group = text_bind_group,
            .rectangle_vertex_buffer = rectangle_vertex_buffer,
            .text_vertex_buffer = text_vertex_buffer,
            .text_vertices = text_vertices,
            .bitmap_font = bitmap_font,
            .bitmap_font_texture = bitmap_font_texture_resources.texture,
            .bitmap_font_texture_view = bitmap_font_texture_resources.view,
            .bitmap_font_sampler = bitmap_font_texture_resources.sampler,
            .font_atlas = font_atlas,
            .font_texture = font_texture_resources.texture,
            .font_texture_view = font_texture_resources.view,
            .font_sampler = font_texture_resources.sampler,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.text_vertices);
        self.text_bind_group.release();
        self.bitmap_text_bind_group.release();
        self.bitmap_font_sampler.release();
        self.bitmap_font_texture_view.release();
        self.bitmap_font_texture.release();
        self.font_sampler.release();
        self.font_texture_view.release();
        self.font_texture.release();
        self.font_atlas.deinit();
        self.text_vertex_buffer.release();
        self.rectangle_vertex_buffer.release();
        self.text_pipeline.release();
        self.bitmap_text_pipeline.release();
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

    pub fn drawTextEx(self: *Renderer, text: Text) void {
        const view = std.unicode.Utf8View.init(text.text) catch return;
        const start_vertex = self.text_vertex_count;
        const framebuffer_size = self.framebufferSize();
        const color = colorComponents(text.color);
        const scale_factor = text.size / self.font_atlas.base_size;

        var iterator = view.iterator();
        var text_offset_x: f32 = 0.0;
        var text_offset_y: f32 = 0.0;

        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint == '\n') {
                text_offset_y += text.size + text_line_spacing;
                text_offset_x = 0.0;
                continue;
            }

            const glyph = self.font_atlas.glyph(codepoint) orelse self.font_atlas.glyph('?') orelse continue;

            if ((codepoint != ' ') and (codepoint != '\t')) {
                if (glyph.atlas_bounds) |atlas_bounds| {
                    if ((glyph.width > 0.0) and (glyph.height > 0.0)) {
                        std.debug.assert(self.text_vertex_count + text_vertex_count_per_glyph <= max_text_vertices_per_frame);
                        appendGlyphVertices(
                            self.text_vertices[self.text_vertex_count..][0..text_vertex_count_per_glyph],
                            .{
                                .x = text.position.x + text_offset_x + glyph.offset_x * scale_factor,
                                .y = text.position.y + text_offset_y + glyph.offset_y * scale_factor,
                            },
                            .{
                                .x = glyph.width * scale_factor,
                                .y = glyph.height * scale_factor,
                            },
                            atlas_bounds,
                            self.font_atlas.width,
                            self.font_atlas.height,
                            framebuffer_size,
                            color,
                        );
                        self.text_vertex_count += text_vertex_count_per_glyph;
                    }
                }
            }

            if (glyph.advance_x == 0.0) {
                text_offset_x += glyph.width * scale_factor;
            } else {
                text_offset_x += glyph.advance_x * scale_factor;
            }
        }

        self.drawTextVertices(start_vertex, self.text_pipeline, self.text_bind_group);
    }

    fn drawTextVertices(self: *Renderer, start_vertex: usize, pipeline: wgpu.RenderPipeline, bind_group: wgpu.BindGroup) void {
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

const Glyph = struct {
    offset_x: f32,
    offset_y: f32,
    advance_x: f32,
    width: f32,
    height: f32,
    atlas_bounds: ?Bounds,
};

const default_font_texture_width = 128;
const default_font_texture_height = 128;
const default_font_first_codepoint = 32;
const default_font_glyph_count = 224;
const default_font_base_size = 10.0;
const default_font_chars_height = 10;
const default_font_chars_divisor = 1;

const default_font_data = [_]u32{
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00200020, 0x0001b000, 0x00000000, 0x00000000, 0x8ef92520, 0x00020a00, 0x7dbe8000, 0x1f7df45f,
    0x4a2bf2a0, 0x0852091e, 0x41224000, 0x10041450, 0x2e292020, 0x08220812, 0x41222000, 0x10041450, 0x10f92020, 0x3efa084c, 0x7d22103c, 0x107df7de,
    0xe8a12020, 0x08220832, 0x05220800, 0x10450410, 0xa4a3f000, 0x08520832, 0x05220400, 0x10450410, 0xe2f92020, 0x0002085e, 0x7d3e0281, 0x107df41f,
    0x00200000, 0x8001b000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0xc0000fbe, 0xfbf7e00f, 0x5fbf7e7d, 0x0050bee8, 0x440808a2, 0x0a142fe8, 0x50810285, 0x0050a048,
    0x49e428a2, 0x0a142828, 0x40810284, 0x0048a048, 0x10020fbe, 0x09f7ebaf, 0xd89f3e84, 0x0047a04f, 0x09e48822, 0x0a142aa1, 0x50810284, 0x0048a048,
    0x04082822, 0x0a142fa0, 0x50810285, 0x0050a248, 0x00008fbe, 0xfbf42021, 0x5f817e7d, 0x07d09ce8, 0x00008000, 0x00000fe0, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x000c0180,
    0xdfbf4282, 0x0bfbf7ef, 0x42850505, 0x004804bf, 0x50a142c6, 0x08401428, 0x42852505, 0x00a808a0, 0x50a146aa, 0x08401428, 0x42852505, 0x00081090,
    0x5fa14a92, 0x0843f7e8, 0x7e792505, 0x00082088, 0x40a15282, 0x08420128, 0x40852489, 0x00084084, 0x40a16282, 0x0842022a, 0x40852451, 0x00088082,
    0xc0bf4282, 0xf843f42f, 0x7e85fc21, 0x3e0900bf, 0x00000000, 0x00000004, 0x00000000, 0x000c0180, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x04000402, 0x41482000, 0x00000000, 0x00000800,
    0x04000404, 0x4100203c, 0x00000000, 0x00000800, 0xf7df7df0, 0x514bef85, 0xbefbefbe, 0x04513bef, 0x14414500, 0x494a2885, 0xa28a28aa, 0x04510820,
    0xf44145f0, 0x474a289d, 0xa28a28aa, 0x04510be0, 0x14414510, 0x494a2884, 0xa28a28aa, 0x02910a00, 0xf7df7df0, 0xd14a2f85, 0xbefbe8aa, 0x011f7be0,
    0x00000000, 0x00400804, 0x20080000, 0x00000000, 0x00000000, 0x00600f84, 0x20080000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0xac000000, 0x00000f01, 0x00000000, 0x00000000, 0x24000000, 0x00000f01, 0x00000000, 0x06000000, 0x24000000, 0x00000f01, 0x00000000, 0x09108000,
    0x24fa28a2, 0x00000f01, 0x00000000, 0x013e0000, 0x2242252a, 0x00000f52, 0x00000000, 0x038a8000, 0x2422222a, 0x00000f29, 0x00000000, 0x010a8000,
    0x2412252a, 0x00000f01, 0x00000000, 0x010a8000, 0x24fbe8be, 0x00000f01, 0x00000000, 0x0ebe8000, 0xac020000, 0x00000f01, 0x00000000, 0x00048000,
    0x0003e000, 0x00000f00, 0x00000000, 0x00008000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000038, 0x8443b80e, 0x00203a03,
    0x02bea080, 0xf0000020, 0xc452208a, 0x04202b02, 0xf8029122, 0x07f0003b, 0xe44b388e, 0x02203a02, 0x081e8a1c, 0x0411e92a, 0xf4420be0, 0x01248202,
    0xe8140414, 0x05d104ba, 0xe7c3b880, 0x00893a0a, 0x283c0e1c, 0x04500902, 0xc4400080, 0x00448002, 0xe8208422, 0x04500002, 0x80400000, 0x05200002,
    0x083e8e00, 0x04100002, 0x804003e0, 0x07000042, 0xf8008400, 0x07f00003, 0x80400000, 0x04000022, 0x00000000, 0x00000000, 0x80400000, 0x04000002,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00800702, 0x1848a0c2, 0x84010000, 0x02920921, 0x01042642, 0x00005121, 0x42023f7f, 0x00291002,
    0xefc01422, 0x7efdfbf7, 0xefdfa109, 0x03bbbbf7, 0x28440f12, 0x42850a14, 0x20408109, 0x01111010, 0x28440408, 0x42850a14, 0x2040817f, 0x01111010,
    0xefc78204, 0x7efdfbf7, 0xe7cf8109, 0x011111f3, 0x2850a932, 0x42850a14, 0x2040a109, 0x01111010, 0x2850b840, 0x42850a14, 0xefdfbf79, 0x03bbbbf7,
    0x001fa020, 0x00000000, 0x00001000, 0x00000000, 0x00002070, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x08022800, 0x00012283, 0x02430802, 0x01010001, 0x8404147c, 0x20000144, 0x80048404, 0x00823f08, 0xdfbf4284, 0x7e03f7ef, 0x142850a1, 0x0000210a,
    0x50a14684, 0x528a1428, 0x142850a1, 0x03efa17a, 0x50a14a9e, 0x52521428, 0x142850a1, 0x02081f4a, 0x50a15284, 0x4a221428, 0xf42850a1, 0x03efa14b,
    0x50a16284, 0x4a521428, 0x042850a1, 0x0228a17a, 0xdfbf427c, 0x7e8bf7ef, 0xf7efdfbf, 0x03efbd0b, 0x00000000, 0x04000000, 0x00000000, 0x00000008,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00200508, 0x00840400, 0x11458122, 0x00014210,
    0x00514294, 0x51420800, 0x20a22a94, 0x0050a508, 0x00200000, 0x00000000, 0x00050000, 0x08000000, 0xfefbefbe, 0xfbefbefb, 0xfbeb9114, 0x00fbefbe,
    0x20820820, 0x8a28a20a, 0x8a289114, 0x3e8a28a2, 0xfefbefbe, 0xfbefbe0b, 0x8a289114, 0x008a28a2, 0x228a28a2, 0x08208208, 0x8a289114, 0x088a28a2,
    0xfefbefbe, 0xfbefbefb, 0xfa2f9114, 0x00fbefbe, 0x00000000, 0x00000040, 0x00000000, 0x00000000, 0x00000000, 0x00000020, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00210100, 0x00000004, 0x00000000, 0x00000000, 0x14508200, 0x00001402, 0x00000000, 0x00000000,
    0x00000010, 0x00000020, 0x00000000, 0x00000000, 0xa28a28be, 0x00002228, 0x00000000, 0x00000000, 0xa28a28aa, 0x000022e8, 0x00000000, 0x00000000,
    0xa28a28aa, 0x000022a8, 0x00000000, 0x00000000, 0xa28a28aa, 0x000022e8, 0x00000000, 0x00000000, 0xbefbefbe, 0x00003e2f, 0x00000000, 0x00000000,
    0x00000004, 0x00002028, 0x00000000, 0x00000000, 0x80000000, 0x00003e0f, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
};

const default_font_char_widths = [_]u8{
    3, 1, 4, 6, 5, 7, 6, 2, 3, 3, 5, 5, 2, 4, 1, 7, 5, 2, 5, 5, 5, 5, 5, 5, 5, 5, 1, 1, 3, 4, 3, 6,
    7, 6, 6, 6, 6, 6, 6, 6, 6, 3, 5, 6, 5, 7, 6, 6, 6, 6, 6, 6, 7, 6, 7, 7, 6, 6, 6, 2, 7, 2, 3, 5,
    2, 5, 5, 5, 5, 5, 4, 5, 5, 1, 2, 5, 2, 5, 5, 5, 5, 5, 5, 5, 4, 5, 5, 5, 5, 5, 5, 3, 1, 3, 4, 4,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 5, 5, 5, 7, 1, 5, 3, 7, 3, 5, 4, 1, 7, 4, 3, 5, 3, 3, 2, 5, 6, 1, 2, 2, 3, 5, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 7, 6, 6, 6, 6, 6, 3, 3, 3, 3, 7, 6, 6, 6, 6, 6, 6, 5, 6, 6, 6, 6, 6, 6, 4, 6,
    5, 5, 5, 5, 5, 5, 9, 5, 5, 5, 5, 5, 2, 2, 3, 3, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 3, 5,
};

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
        var current_line: u32 = 0;
        var current_pos_x: u32 = default_font_chars_divisor;
        var test_pos_x: u32 = default_font_chars_divisor;

        for (&glyphs, default_font_char_widths) |*glyph_out, char_width| {
            var x = current_pos_x;
            var y = default_font_chars_divisor + current_line * (default_font_chars_height + default_font_chars_divisor);

            test_pos_x += @as(u32, char_width) + default_font_chars_divisor;

            if (test_pos_x >= default_font_texture_width) {
                current_line += 1;
                current_pos_x = 2 * default_font_chars_divisor + char_width;
                test_pos_x = current_pos_x;

                x = default_font_chars_divisor;
                y = default_font_chars_divisor + current_line * (default_font_chars_height + default_font_chars_divisor);
            } else {
                current_pos_x = test_pos_x;
            }

            glyph_out.* = .{
                .atlas_bounds = .{
                    .left = @floatFromInt(x),
                    .top = @floatFromInt(y),
                    .right = @floatFromInt(x + char_width),
                    .bottom = @floatFromInt(y + default_font_chars_height),
                },
                .width = @floatFromInt(char_width),
                .height = default_font_chars_height,
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

const FontAtlas = struct {
    glyphs: std.AutoHashMap(u21, Glyph),
    width: f32,
    height: f32,
    base_size: f32,

    fn init(allocator: std.mem.Allocator) !FontAtlas {
        const parsed = try std.json.parseFromSlice(FontJson, allocator, ui_font_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        var glyphs = std.AutoHashMap(u21, Glyph).init(allocator);
        errdefer glyphs.deinit();

        for (parsed.value.glyphs) |json_glyph| {
            const unicode = json_glyph.unicode orelse continue;
            const plane_bounds = if (json_glyph.planeBounds) |bounds| bounds.toBounds() else null;
            const atlas_bounds = if (json_glyph.atlasBounds) |bounds| bounds.toBounds() else null;

            var loaded_glyph = Glyph{
                .offset_x = 0.0,
                .offset_y = 0.0,
                .advance_x = json_glyph.advance * parsed.value.atlas.size,
                .width = 0.0,
                .height = 0.0,
                .atlas_bounds = atlas_bounds,
            };

            if (plane_bounds) |bounds| {
                loaded_glyph.offset_x = bounds.left * parsed.value.atlas.size;
                loaded_glyph.offset_y = (bounds.top - parsed.value.metrics.ascender) * parsed.value.atlas.size;
                loaded_glyph.width = (bounds.right - bounds.left) * parsed.value.atlas.size;
                loaded_glyph.height = (bounds.bottom - bounds.top) * parsed.value.atlas.size;
            }

            try glyphs.put(@intCast(unicode), loaded_glyph);
        }

        return .{
            .glyphs = glyphs,
            .width = parsed.value.atlas.width,
            .height = parsed.value.atlas.height,
            .base_size = (parsed.value.metrics.descender - parsed.value.metrics.ascender) * parsed.value.atlas.size,
        };
    }

    fn deinit(self: *FontAtlas) void {
        self.glyphs.deinit();
    }

    fn glyph(self: *const FontAtlas, codepoint: u21) ?Glyph {
        return self.glyphs.get(codepoint);
    }
};

const FontJson = struct {
    atlas: struct {
        width: f32,
        height: f32,
        size: f32,
    },
    metrics: struct {
        ascender: f32,
        descender: f32,
    },
    glyphs: []const GlyphJson,
};

const GlyphJson = struct {
    unicode: ?u32 = null,
    advance: f32,
    planeBounds: ?BoundsJson = null,
    atlasBounds: ?BoundsJson = null,
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
    std.debug.assert(default_font_data.len * 32 == pixel_count);

    const rgba_pixels = try allocator.alloc(u8, pixel_count * 4);
    defer allocator.free(rgba_pixels);

    for (default_font_data, 0..) |bits, word_index| {
        const base_pixel = word_index * 32;
        for (0..32) |bit_index| {
            const pixel_index = base_pixel + bit_index;
            const alpha: u8 = if ((bits & (@as(u32, 1) << @intCast(bit_index))) != 0) 255 else 0;
            rgba_pixels[pixel_index * 4 + 0] = 255;
            rgba_pixels[pixel_index * 4 + 1] = 255;
            rgba_pixels[pixel_index * 4 + 2] = 255;
            rgba_pixels[pixel_index * 4 + 3] = alpha;
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
