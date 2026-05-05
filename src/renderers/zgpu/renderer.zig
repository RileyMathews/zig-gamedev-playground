const std = @import("std");

const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zgui = @import("zgui");

const wgpu = zgpu.wgpu;

const monogram_font = @import("monogram_font.zig");

pub const Renderer = ZgpuRenderer;

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

const FrameUniforms = extern struct {
    framebuffer_size: [2]f32,
    padding: [2]f32 = .{ 0.0, 0.0 },
};

const RectangleInstance = extern struct {
    position: [2]f32,
    size: [2]f32,
    color: [4]f32,
};

const GlyphInstance = extern struct {
    position: [2]f32,
    size: [2]f32,
    uv_min: [2]f32,
    uv_max: [2]f32,
    color: [4]f32,
};

const quad_vertex_count = 6;
const max_rectangles_per_frame = 1024;
const max_text_glyphs_per_frame = 4096;
const text_line_spacing: f32 = 2.0;

pub const ZgpuRenderer = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    frame_bind_group_layout: wgpu.BindGroupLayout,
    frame_bind_group: wgpu.BindGroup,
    frame_uniform_buffer: wgpu.Buffer,
    rectangle_pipeline: wgpu.RenderPipeline,
    bitmap_text_pipeline: wgpu.RenderPipeline,
    text_bind_group_layout: wgpu.BindGroupLayout,
    bitmap_text_bind_group: wgpu.BindGroup,
    rectangle_instance_buffer: wgpu.Buffer,
    text_instance_buffer: wgpu.Buffer,
    text_instances: []GlyphInstance,
    bitmap_font: BitmapFont,
    bitmap_font_texture: wgpu.Texture,
    bitmap_font_texture_view: wgpu.TextureView,
    bitmap_font_sampler: wgpu.Sampler,
    rectangle_count: usize = 0,
    text_instance_count: usize = 0,

    pub const Frame = struct {
        renderer: *ZgpuRenderer,
        back_buffer_view: wgpu.TextureView,
        encoder: wgpu.CommandEncoder,
        pass: wgpu.RenderPassEncoder,
        ended: bool = false,

        pub fn beginDebugUi(self: *Frame, screen_width: u32, screen_height: u32) void {
            _ = self;
            zgui.backend.newFrame(screen_width, screen_height);
        }

        pub fn endDebugUi(self: *Frame) void {
            zgui.backend.draw(self.pass);
        }

        pub fn end(self: *Frame) void {
            if (self.ended) return;
            self.ended = true;

            const renderer = self.renderer;
            zgpu.endReleasePass(self.pass);

            const commands = self.encoder.finish(null);

            renderer.gctx.submit(&.{commands});
            _ = renderer.gctx.present();

            commands.release();
            self.encoder.release();
            self.back_buffer_view.release();
        }

        pub fn drawRectangle(self: *Frame, rectangle: Rectangle) void {
            const renderer = self.renderer;
            if (renderer.rectangle_count >= max_rectangles_per_frame) return;

            const instance = rectangleInstance(rectangle);
            const byte_offset = renderer.rectangle_count * @sizeOf(RectangleInstance);

            renderer.gctx.queue.writeBuffer(renderer.rectangle_instance_buffer, byte_offset, RectangleInstance, &[_]RectangleInstance{instance});

            self.pass.setPipeline(renderer.rectangle_pipeline);
            self.pass.setBindGroup(0, renderer.frame_bind_group, null);
            self.pass.setVertexBuffer(0, renderer.rectangle_instance_buffer, @intCast(byte_offset), @sizeOf(RectangleInstance));
            self.pass.draw(quad_vertex_count, 1, 0, 0);

            renderer.rectangle_count += 1;
        }

        pub fn drawText(self: *Frame, text: Text) void {
            const renderer = self.renderer;
            const view = std.unicode.Utf8View.init(text.text) catch return;
            const start_instance = renderer.text_instance_count;
            const color = colorComponents(text.color);
            const scale_factor = text.size / renderer.bitmap_font.base_size;
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

                const glyph = renderer.bitmap_font.glyph(codepoint) orelse renderer.bitmap_font.glyph('?').?;

                if ((codepoint != ' ') and (codepoint != '\t')) {
                    if (renderer.text_instance_count >= max_text_glyphs_per_frame) break;
                    renderer.text_instances[renderer.text_instance_count] = glyphInstance(
                        .{
                            .x = text.position.x + text_offset_x,
                            .y = text.position.y + text_offset_y,
                        },
                        .{
                            .x = glyph.width * scale_factor,
                            .y = glyph.height * scale_factor,
                        },
                        glyph.atlas_bounds,
                        renderer.bitmap_font.width,
                        renderer.bitmap_font.height,
                        color,
                    );
                    renderer.text_instance_count += 1;
                }

                text_offset_x += glyph.width * scale_factor + spacing;
            }

            self.drawTextInstances(start_instance);
        }

        fn drawTextInstances(self: *Frame, start_instance: usize) void {
            const renderer = self.renderer;
            const instance_count = renderer.text_instance_count - start_instance;
            if (instance_count == 0) return;

            const byte_offset = start_instance * @sizeOf(GlyphInstance);
            const byte_count = instance_count * @sizeOf(GlyphInstance);
            renderer.gctx.queue.writeBuffer(
                renderer.text_instance_buffer,
                byte_offset,
                GlyphInstance,
                renderer.text_instances[start_instance..renderer.text_instance_count],
            );

            self.pass.setPipeline(renderer.bitmap_text_pipeline);
            self.pass.setBindGroup(0, renderer.frame_bind_group, null);
            self.pass.setBindGroup(1, renderer.bitmap_text_bind_group, null);
            self.pass.setVertexBuffer(0, renderer.text_instance_buffer, @intCast(byte_offset), byte_count);
            self.pass.draw(quad_vertex_count, @intCast(instance_count), 0, 0);
        }
    };

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
            .{ .present_mode = .immediate },
        );
        errdefer gctx.destroy(allocator);

        const bitmap_font = BitmapFont.init();

        var bitmap_font_texture_resources = try createBitmapFontTextureResources(allocator, gctx);
        errdefer bitmap_font_texture_resources.deinit();

        const frame_bind_group_layout = createFrameBindGroupLayout(gctx);
        errdefer frame_bind_group_layout.release();

        const text_bind_group_layout = createTextBindGroupLayout(gctx);
        errdefer text_bind_group_layout.release();

        const frame_uniform_buffer = gctx.device.createBuffer(.{
            .usage = .{ .uniform = true, .copy_dst = true },
            .size = @sizeOf(FrameUniforms),
        });
        errdefer frame_uniform_buffer.release();

        const frame_bind_group = createFrameBindGroup(gctx, frame_bind_group_layout, frame_uniform_buffer);
        errdefer frame_bind_group.release();

        const bitmap_text_bind_group = createTextBindGroup(gctx, text_bind_group_layout, bitmap_font_texture_resources.view, bitmap_font_texture_resources.sampler);
        errdefer bitmap_text_bind_group.release();

        const rectangle_pipeline = createRectanglePipeline(gctx, frame_bind_group_layout);
        errdefer rectangle_pipeline.release();

        const bitmap_text_pipeline = createBitmapTextPipeline(gctx, frame_bind_group_layout, text_bind_group_layout);
        errdefer bitmap_text_pipeline.release();

        const rectangle_instance_buffer = gctx.device.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @sizeOf(RectangleInstance) * max_rectangles_per_frame,
        });
        errdefer rectangle_instance_buffer.release();

        const text_instance_buffer = gctx.device.createBuffer(.{
            .usage = .{ .vertex = true, .copy_dst = true },
            .size = @sizeOf(GlyphInstance) * max_text_glyphs_per_frame,
        });
        errdefer text_instance_buffer.release();

        const text_instances = try allocator.alloc(GlyphInstance, max_text_glyphs_per_frame);
        errdefer allocator.free(text_instances);

        return .{
            .allocator = allocator,
            .gctx = gctx,
            .frame_bind_group_layout = frame_bind_group_layout,
            .frame_bind_group = frame_bind_group,
            .frame_uniform_buffer = frame_uniform_buffer,
            .rectangle_pipeline = rectangle_pipeline,
            .bitmap_text_pipeline = bitmap_text_pipeline,
            .text_bind_group_layout = text_bind_group_layout,
            .bitmap_text_bind_group = bitmap_text_bind_group,
            .rectangle_instance_buffer = rectangle_instance_buffer,
            .text_instance_buffer = text_instance_buffer,
            .text_instances = text_instances,
            .bitmap_font = bitmap_font,
            .bitmap_font_texture = bitmap_font_texture_resources.texture,
            .bitmap_font_texture_view = bitmap_font_texture_resources.view,
            .bitmap_font_sampler = bitmap_font_texture_resources.sampler,
        };
    }

    pub fn deinit(self: *ZgpuRenderer) void {
        self.allocator.free(self.text_instances);
        self.bitmap_text_bind_group.release();
        self.frame_bind_group.release();
        self.bitmap_font_sampler.release();
        self.bitmap_font_texture_view.release();
        self.bitmap_font_texture.release();
        self.text_instance_buffer.release();
        self.rectangle_instance_buffer.release();
        self.frame_uniform_buffer.release();
        self.bitmap_text_pipeline.release();
        self.rectangle_pipeline.release();
        self.text_bind_group_layout.release();
        self.frame_bind_group_layout.release();
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

    pub fn initDebugUi(self: *ZgpuRenderer, window: *zglfw.Window) !void {
        zgui.backend.init(
            window,
            self.gctx.device,
            @intFromEnum(zgpu.GraphicsContext.swapchain_format),
            @intFromEnum(wgpu.TextureFormat.undef),
        );
    }

    pub fn deinitDebugUi(self: *ZgpuRenderer) void {
        _ = self;
        zgui.backend.deinit();
    }

    pub fn beginFrame(self: *ZgpuRenderer, clear_color: Color) ?Frame {
        if (!self.gctx.canRender()) return null;

        self.rectangle_count = 0;
        self.text_instance_count = 0;

        const framebuffer_size = self.framebufferSize();
        const frame_uniforms = FrameUniforms{ .framebuffer_size = .{ framebuffer_size.x, framebuffer_size.y } };
        self.gctx.queue.writeBuffer(self.frame_uniform_buffer, 0, FrameUniforms, &[_]FrameUniforms{frame_uniforms});

        const back_buffer_view = self.gctx.swapchain.getCurrentTextureView();
        const encoder = self.gctx.device.createCommandEncoder(null);

        const pass = zgpu.beginRenderPassSimple(
            encoder,
            .clear,
            back_buffer_view,
            clear_color.toWgpu(),
            null,
            null,
        );

        return .{
            .renderer = self,
            .back_buffer_view = back_buffer_view,
            .encoder = encoder,
            .pass = pass,
        };
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

fn createFrameBindGroupLayout(gctx: *zgpu.GraphicsContext) wgpu.BindGroupLayout {
    const entries = [_]wgpu.BindGroupLayoutEntry{
        zgpu.bufferEntry(0, .{ .vertex = true }, .uniform, false, @sizeOf(FrameUniforms)),
    };

    return gctx.device.createBindGroupLayout(.{
        .entry_count = entries.len,
        .entries = &entries,
    });
}

fn createFrameBindGroup(gctx: *zgpu.GraphicsContext, layout: wgpu.BindGroupLayout, buffer: wgpu.Buffer) wgpu.BindGroup {
    const entries = [_]wgpu.BindGroupEntry{.{
        .binding = 0,
        .buffer = buffer,
        .size = @sizeOf(FrameUniforms),
    }};

    return gctx.device.createBindGroup(.{
        .layout = layout,
        .entry_count = entries.len,
        .entries = &entries,
    });
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

fn createBitmapTextPipeline(gctx: *zgpu.GraphicsContext, frame_bind_group_layout: wgpu.BindGroupLayout, text_bind_group_layout: wgpu.BindGroupLayout) wgpu.RenderPipeline {
    const shader_module = zgpu.createWgslShaderModule(
        gctx.device,
        @embedFile("text_bitmap.wgsl"),
        "text-bitmap",
    );
    defer shader_module.release();

    const bind_group_layouts = [_]wgpu.BindGroupLayout{ frame_bind_group_layout, text_bind_group_layout };
    const pipeline_layout = gctx.device.createPipelineLayout(.{
        .bind_group_layout_count = bind_group_layouts.len,
        .bind_group_layouts = &bind_group_layouts,
    });
    defer pipeline_layout.release();

    const vertex_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = @offsetOf(GlyphInstance, "position"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(GlyphInstance, "size"), .shader_location = 1 },
        .{ .format = .float32x2, .offset = @offsetOf(GlyphInstance, "uv_min"), .shader_location = 2 },
        .{ .format = .float32x2, .offset = @offsetOf(GlyphInstance, "uv_max"), .shader_location = 3 },
        .{ .format = .float32x4, .offset = @offsetOf(GlyphInstance, "color"), .shader_location = 4 },
    };
    const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
        .array_stride = @sizeOf(GlyphInstance),
        .step_mode = .instance,
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

fn createRectanglePipeline(gctx: *zgpu.GraphicsContext, frame_bind_group_layout: wgpu.BindGroupLayout) wgpu.RenderPipeline {
    const shader_module = zgpu.createWgslShaderModule(
        gctx.device,
        @embedFile("rectangle.wgsl"),
        "rectangle",
    );
    defer shader_module.release();

    const vertex_attributes = [_]wgpu.VertexAttribute{
        .{ .format = .float32x2, .offset = @offsetOf(RectangleInstance, "position"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(RectangleInstance, "size"), .shader_location = 1 },
        .{ .format = .float32x4, .offset = @offsetOf(RectangleInstance, "color"), .shader_location = 2 },
    };
    const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
        .array_stride = @sizeOf(RectangleInstance),
        .step_mode = .instance,
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    }};

    const bind_group_layouts = [_]wgpu.BindGroupLayout{frame_bind_group_layout};
    const pipeline_layout = gctx.device.createPipelineLayout(.{
        .bind_group_layout_count = bind_group_layouts.len,
        .bind_group_layouts = &bind_group_layouts,
    });
    defer pipeline_layout.release();

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
            .target_count = 1,
            .targets = &.{.{ .format = zgpu.GraphicsContext.swapchain_format }},
        },
    });
}

fn glyphInstance(
    position: Vec2,
    size: Vec2,
    atlas_bounds: Bounds,
    atlas_width: f32,
    atlas_height: f32,
    color: [4]f32,
) GlyphInstance {
    const uv_left = atlas_bounds.left / atlas_width;
    const uv_top = atlas_bounds.top / atlas_height;
    const uv_right = atlas_bounds.right / atlas_width;
    const uv_bottom = atlas_bounds.bottom / atlas_height;

    return .{
        .position = .{ position.x, position.y },
        .size = .{ size.x, size.y },
        .uv_min = .{ uv_left, uv_top },
        .uv_max = .{ uv_right, uv_bottom },
        .color = color,
    };
}

fn rectangleInstance(rectangle: Rectangle) RectangleInstance {
    return .{
        .position = .{ rectangle.position.x, rectangle.position.y },
        .size = .{ rectangle.size.x, rectangle.size.y },
        .color = colorComponents(rectangle.color),
    };
}

fn colorComponents(color: Color) [4]f32 {
    return .{
        @floatCast(color.r),
        @floatCast(color.g),
        @floatCast(color.b),
        @floatCast(color.a),
    };
}
