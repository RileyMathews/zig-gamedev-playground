const std = @import("std");

const vk = @import("vulkan");
const zglfw = @import("zglfw");
const zgui = @import("zgui");

const monogram_font = @import("monogram_font.zig");

const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;
const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;

const rectangle_vert_spv align(@alignOf(u32)) = @embedFile("rectangle_vertex_shader").*;
const rectangle_frag_spv align(@alignOf(u32)) = @embedFile("rectangle_fragment_shader").*;
const text_vert_spv align(@alignOf(u32)) = @embedFile("text_vertex_shader").*;
const text_frag_spv align(@alignOf(u32)) = @embedFile("text_fragment_shader").*;

pub const Renderer = VulkanRenderer;

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

    fn toVkClear(self: Color) vk.ClearValue {
        return .{ .color = .{ .float_32 = .{
            @floatCast(self.r),
            @floatCast(self.g),
            @floatCast(self.b),
            @floatCast(self.a),
        } } };
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

const FrameConstants = extern struct {
    framebuffer_size: [2]f32,
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

const max_frames_in_flight = 2;
const app_name = "zig-gamedev playground";
const required_device_extensions = [_][*:0]const u8{vk.extensions.khr_swapchain.name};

pub const VulkanRenderer = struct {
    allocator: std.mem.Allocator,
    window: *zglfw.Window,

    vkb: BaseWrapper,
    instance: Instance = undefined,
    dev: Device = undefined,
    has_instance: bool = false,
    has_device: bool = false,
    surface: vk.SurfaceKHR = .null_handle,
    pdev: vk.PhysicalDevice = .null_handle,
    props: vk.PhysicalDeviceProperties = undefined,
    mem_props: vk.PhysicalDeviceMemoryProperties = undefined,
    graphics_queue: Queue = .{},
    present_queue: Queue = .{},

    swapchain: SwapchainResources = .{},
    render_pass: vk.RenderPass = .null_handle,
    framebuffers: ?[]vk.Framebuffer = null,
    command_pool: vk.CommandPool = .null_handle,
    command_buffers: ?[]vk.CommandBuffer = null,
    image_fences: ?[]vk.Fence = null,

    image_available: [max_frames_in_flight]vk.Semaphore = [_]vk.Semaphore{.null_handle} ** max_frames_in_flight,
    render_finished: [max_frames_in_flight]vk.Semaphore = [_]vk.Semaphore{.null_handle} ** max_frames_in_flight,
    in_flight_fences: [max_frames_in_flight]vk.Fence = [_]vk.Fence{.null_handle} ** max_frames_in_flight,
    current_frame: usize = 0,
    current_image_index: u32 = 0,
    current_command_buffer: ?vk.CommandBuffer = null,

    rectangle_pipeline_layout: vk.PipelineLayout = .null_handle,
    rectangle_pipeline: vk.Pipeline = .null_handle,
    text_descriptor_set_layout: vk.DescriptorSetLayout = .null_handle,
    text_pipeline_layout: vk.PipelineLayout = .null_handle,
    text_pipeline: vk.Pipeline = .null_handle,
    text_descriptor_pool: vk.DescriptorPool = .null_handle,
    text_descriptor_set: vk.DescriptorSet = .null_handle,

    rectangle_instance_buffer: BufferResource = .{},
    text_instance_buffer: BufferResource = .{},
    bitmap_font: BitmapFont = undefined,
    bitmap_font_texture: FontTextureResources = .{},

    rectangle_count: usize = 0,
    text_instance_count: usize = 0,
    debug_ui_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, window: *zglfw.Window) !VulkanRenderer {
        if (!zglfw.isVulkanSupported()) return error.VulkanUnavailable;

        var self = VulkanRenderer{
            .allocator = allocator,
            .window = window,
            .vkb = BaseWrapper.load(getGlfwInstanceProcAddr),
        };
        errdefer self.deinit();

        const instance_handle = try createInstance(&self.vkb, allocator);
        const vki = try allocator.create(InstanceWrapper);
        vki.* = InstanceWrapper.load(instance_handle, self.vkb.dispatch.vkGetInstanceProcAddr.?);
        self.instance = Instance.init(instance_handle, vki);
        self.has_instance = true;

        try zglfw.createWindowSurface(self.instance.handle, window, null, &self.surface);

        const candidate = try pickPhysicalDevice(self.instance, allocator, self.surface);
        self.pdev = candidate.pdev;
        self.props = candidate.props;

        const device_handle = try initializeDevice(self.instance, candidate);
        const vkd = try allocator.create(DeviceWrapper);
        vkd.* = DeviceWrapper.load(device_handle, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        self.dev = Device.init(device_handle, vkd);
        self.has_device = true;

        self.graphics_queue = Queue.init(self.dev, candidate.queues.graphics_family);
        self.present_queue = Queue.init(self.dev, candidate.queues.present_family);
        self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

        self.swapchain = try self.createSwapchain(.null_handle);
        self.render_pass = try self.createRenderPass(self.swapchain.surface_format.format);
        self.command_pool = try self.dev.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.graphics_queue.family,
        }, null);

        try self.createSwapchainDependents();
        try self.createSyncObjects();

        const frame_constants_range = framePushConstantRange();
        self.rectangle_pipeline_layout = try self.dev.createPipelineLayout(&.{
            .flags = .{},
            .set_layout_count = 0,
            .p_set_layouts = undefined,
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&frame_constants_range),
        }, null);
        self.rectangle_pipeline = try self.createRectanglePipeline();

        self.text_descriptor_set_layout = try self.createTextDescriptorSetLayout();
        self.text_pipeline_layout = try self.createTextPipelineLayout();
        self.text_pipeline = try self.createTextPipeline();
        self.text_descriptor_pool = try self.createTextDescriptorPool();

        self.rectangle_instance_buffer = try self.createBuffer(
            @sizeOf(RectangleInstance) * max_rectangles_per_frame,
            .{ .vertex_buffer_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
            true,
        );
        self.text_instance_buffer = try self.createBuffer(
            @sizeOf(GlyphInstance) * max_text_glyphs_per_frame,
            .{ .vertex_buffer_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
            true,
        );
        self.bitmap_font = BitmapFont.init();
        self.bitmap_font_texture = try self.createBitmapFontTextureResources();
        self.text_descriptor_set = try self.createTextDescriptorSet();

        return self;
    }

    pub fn deinit(self: *VulkanRenderer) void {
        if (self.has_device) {
            self.dev.deviceWaitIdle() catch {};
        }

        self.bitmap_font_texture.deinit(self);
        self.text_instance_buffer.deinit(self);
        self.rectangle_instance_buffer.deinit(self);

        if (self.text_descriptor_pool != .null_handle) self.dev.destroyDescriptorPool(self.text_descriptor_pool, null);
        if (self.text_pipeline != .null_handle) self.dev.destroyPipeline(self.text_pipeline, null);
        if (self.text_pipeline_layout != .null_handle) self.dev.destroyPipelineLayout(self.text_pipeline_layout, null);
        if (self.text_descriptor_set_layout != .null_handle) self.dev.destroyDescriptorSetLayout(self.text_descriptor_set_layout, null);
        if (self.rectangle_pipeline != .null_handle) self.dev.destroyPipeline(self.rectangle_pipeline, null);
        if (self.rectangle_pipeline_layout != .null_handle) self.dev.destroyPipelineLayout(self.rectangle_pipeline_layout, null);

        self.destroySwapchainDependents();
        self.destroySyncObjects();
        if (self.command_pool != .null_handle) self.dev.destroyCommandPool(self.command_pool, null);
        if (self.render_pass != .null_handle) self.dev.destroyRenderPass(self.render_pass, null);
        self.swapchain.deinit(self);

        if (self.has_device) {
            self.dev.destroyDevice(null);
            self.allocator.destroy(self.dev.wrapper);
        }
        if (self.surface != .null_handle and self.has_instance) self.instance.destroySurfaceKHR(self.surface, null);
        if (self.has_instance) {
            self.instance.destroyInstance(null);
            self.allocator.destroy(self.instance.wrapper);
        }
    }

    pub fn framebufferSize(self: *VulkanRenderer) Vec2 {
        return .{
            .x = @floatFromInt(self.swapchain.extent.width),
            .y = @floatFromInt(self.swapchain.extent.height),
        };
    }

    pub fn framebufferPixelSize(self: *VulkanRenderer) FramebufferPixelSize {
        return .{
            .width = self.swapchain.extent.width,
            .height = self.swapchain.extent.height,
        };
    }

    pub fn currentRenderPass(self: *VulkanRenderer) vk.CommandBuffer {
        return self.current_command_buffer.?;
    }

    pub fn initDebugUi(self: *VulkanRenderer, window: *zglfw.Window) !void {
        if (!zgui.backend.loadFunctions(versionToU32(vk.API_VERSION_1_3), loadZguiVulkanFunction, self)) {
            return error.DebugUiVulkanLoadFailed;
        }

        zgui.backend.init(.{
            .api_version = versionToU32(vk.API_VERSION_1_3),
            .instance = imguiHandle(self.instance.handle),
            .physical_device = imguiHandle(self.pdev),
            .device = imguiHandle(self.dev.handle),
            .queue_family = self.graphics_queue.family,
            .queue = imguiHandle(self.graphics_queue.handle),
            .descriptor_pool = null,
            .render_pass = imguiHandle(self.render_pass),
            .min_image_count = self.swapchain.min_image_count,
            .image_count = @intCast(self.swapchain.image_views.?.len),
            .msaa_samples = (vk.SampleCountFlags{ .@"1_bit" = true }).toInt(),
            .descriptor_pool_size = 64,
        }, window);
        self.debug_ui_initialized = true;
    }

    pub fn deinitDebugUi(self: *VulkanRenderer) void {
        if (!self.debug_ui_initialized) return;
        zgui.backend.deinit();
        self.debug_ui_initialized = false;
    }

    pub fn beginDebugUi(self: *VulkanRenderer, screen_width: u32, screen_height: u32) void {
        _ = self;
        zgui.backend.newFrame(screen_width, screen_height);
    }

    pub fn endDebugUi(self: *VulkanRenderer) void {
        zgui.backend.render(imguiHandle(self.currentRenderPass()));
    }

    pub fn beginFrame(self: *VulkanRenderer, clear_color: Color) bool {
        const requested_extent = self.windowFramebufferExtent();
        if (requested_extent.width == 0 or requested_extent.height == 0) return false;

        if (requested_extent.width != self.swapchain.extent.width or requested_extent.height != self.swapchain.extent.height) {
            self.recreateSwapchain() catch |err| {
                std.log.err("failed to recreate Vulkan swapchain: {s}", .{@errorName(err)});
                return false;
            };
        }

        const frame_fence = self.in_flight_fences[self.current_frame];
        _ = self.dev.waitForFences(1, @ptrCast(&frame_fence), .true, std.math.maxInt(u64)) catch |err| {
            std.log.err("failed waiting for Vulkan frame fence: {s}", .{@errorName(err)});
            return false;
        };

        const acquired = self.dev.acquireNextImageKHR(
            self.swapchain.handle,
            std.math.maxInt(u64),
            self.image_available[self.current_frame],
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => {
                self.recreateSwapchain() catch |recreate_err| {
                    std.log.err("failed to recreate out-of-date Vulkan swapchain: {s}", .{@errorName(recreate_err)});
                };
                return false;
            },
            else => {
                std.log.err("failed to acquire Vulkan swapchain image: {s}", .{@errorName(err)});
                return false;
            },
        };

        self.current_image_index = acquired.image_index;
        if (self.image_fences) |image_fences| {
            const image_fence = image_fences[self.current_image_index];
            if (image_fence != .null_handle) {
                _ = self.dev.waitForFences(1, @ptrCast(&image_fence), .true, std.math.maxInt(u64)) catch |err| {
                    std.log.err("failed waiting for Vulkan image fence: {s}", .{@errorName(err)});
                    return false;
                };
            }
            image_fences[self.current_image_index] = frame_fence;
        }

        self.dev.resetFences(1, @ptrCast(&frame_fence)) catch |err| {
            std.log.err("failed resetting Vulkan frame fence: {s}", .{@errorName(err)});
            return false;
        };

        const command_buffer = self.command_buffers.?[self.current_image_index];
        self.dev.resetCommandBuffer(command_buffer, .{}) catch |err| {
            std.log.err("failed resetting Vulkan command buffer: {s}", .{@errorName(err)});
            return false;
        };
        self.dev.beginCommandBuffer(command_buffer, &.{}) catch |err| {
            std.log.err("failed beginning Vulkan command buffer: {s}", .{@errorName(err)});
            return false;
        };

        const render_area = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain.extent,
        };
        const clear = clear_color.toVkClear();
        self.dev.cmdBeginRenderPass(command_buffer, &.{
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffers.?[self.current_image_index],
            .render_area = render_area,
            .clear_value_count = 1,
            .p_clear_values = @ptrCast(&clear),
        }, .@"inline");

        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.swapchain.extent.width),
            .height = @floatFromInt(self.swapchain.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };
        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain.extent,
        };
        self.dev.cmdSetViewport(command_buffer, 0, 1, @ptrCast(&viewport));
        self.dev.cmdSetScissor(command_buffer, 0, 1, @ptrCast(&scissor));

        const frame_constants = FrameConstants{ .framebuffer_size = .{
            @floatFromInt(self.swapchain.extent.width),
            @floatFromInt(self.swapchain.extent.height),
        } };
        self.dev.cmdPushConstants(
            command_buffer,
            self.rectangle_pipeline_layout,
            .{ .vertex_bit = true },
            0,
            @sizeOf(FrameConstants),
            @ptrCast(&frame_constants),
        );

        self.current_command_buffer = command_buffer;
        self.rectangle_count = 0;
        self.text_instance_count = 0;
        return true;
    }

    pub fn endFrame(self: *VulkanRenderer) void {
        const command_buffer = self.current_command_buffer orelse return;
        self.dev.cmdEndRenderPass(command_buffer);
        self.dev.endCommandBuffer(command_buffer) catch |err| {
            std.log.err("failed ending Vulkan command buffer: {s}", .{@errorName(err)});
            self.current_command_buffer = null;
            return;
        };

        const wait_stage = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.image_available[self.current_frame]),
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&self.render_finished[self.current_frame]),
        };

        self.dev.queueSubmit(self.graphics_queue.handle, 1, @ptrCast(&submit_info), self.in_flight_fences[self.current_frame]) catch |err| {
            std.log.err("failed submitting Vulkan frame: {s}", .{@errorName(err)});
            self.current_command_buffer = null;
            return;
        };

        const present_result = self.dev.queuePresentKHR(self.present_queue.handle, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.render_finished[self.current_frame]),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain.handle),
            .p_image_indices = @ptrCast(&self.current_image_index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => vk.Result.error_out_of_date_khr,
            else => {
                std.log.err("failed presenting Vulkan frame: {s}", .{@errorName(err)});
                self.current_command_buffer = null;
                return;
            },
        };

        self.current_command_buffer = null;
        self.current_frame = (self.current_frame + 1) % max_frames_in_flight;

        if (present_result == .suboptimal_khr or present_result == .error_out_of_date_khr) {
            self.recreateSwapchain() catch |err| {
                std.log.err("failed recreating Vulkan swapchain after present: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn drawRectangle(self: *VulkanRenderer, rectangle: Rectangle) void {
        std.debug.assert(self.rectangle_count < max_rectangles_per_frame);

        const byte_offset = self.rectangle_count * @sizeOf(RectangleInstance);
        const mapped_instances: [*]RectangleInstance = @ptrCast(@alignCast(self.rectangle_instance_buffer.mapped.?));
        mapped_instances[self.rectangle_count] = rectangleInstance(rectangle);

        const command_buffer = self.currentRenderPass();
        self.dev.cmdBindPipeline(command_buffer, .graphics, self.rectangle_pipeline);
        const offset = [_]vk.DeviceSize{@intCast(byte_offset)};
        self.dev.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&self.rectangle_instance_buffer.buffer), &offset);
        self.dev.cmdDraw(command_buffer, quad_vertex_count, 1, 0, 0);

        self.rectangle_count += 1;
    }

    pub fn drawText(self: *VulkanRenderer, text: Text) void {
        const view = std.unicode.Utf8View.init(text.text) catch return;
        const start_instance = self.text_instance_count;
        const mapped_instances: [*]GlyphInstance = @ptrCast(@alignCast(self.text_instance_buffer.mapped.?));
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
                std.debug.assert(self.text_instance_count < max_text_glyphs_per_frame);
                mapped_instances[self.text_instance_count] = glyphInstance(
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
                    color,
                );
                self.text_instance_count += 1;
            }

            text_offset_x += glyph.width * scale_factor + spacing;
        }

        self.drawTextInstances(start_instance);
    }

    fn drawTextInstances(self: *VulkanRenderer, start_instance: usize) void {
        const instance_count = self.text_instance_count - start_instance;
        if (instance_count == 0) return;

        const byte_offset = start_instance * @sizeOf(GlyphInstance);

        const command_buffer = self.currentRenderPass();
        self.dev.cmdBindPipeline(command_buffer, .graphics, self.text_pipeline);
        self.dev.cmdBindDescriptorSets(
            command_buffer,
            .graphics,
            self.text_pipeline_layout,
            0,
            1,
            @ptrCast(&self.text_descriptor_set),
            0,
            null,
        );
        const offset = [_]vk.DeviceSize{@intCast(byte_offset)};
        self.dev.cmdBindVertexBuffers(command_buffer, 0, 1, @ptrCast(&self.text_instance_buffer.buffer), &offset);
        self.dev.cmdDraw(command_buffer, quad_vertex_count, @intCast(instance_count), 0, 0);
    }

    fn createBuffer(
        self: *VulkanRenderer,
        size: vk.DeviceSize,
        usage: vk.BufferUsageFlags,
        memory_flags: vk.MemoryPropertyFlags,
        map_memory: bool,
    ) !BufferResource {
        const buffer = try self.dev.createBuffer(&.{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        }, null);
        errdefer self.dev.destroyBuffer(buffer, null);

        const requirements = self.dev.getBufferMemoryRequirements(buffer);
        const memory = try self.allocate(requirements, memory_flags);
        errdefer self.dev.freeMemory(memory, null);

        try self.dev.bindBufferMemory(buffer, memory, 0);
        const mapped = if (map_memory) try self.dev.mapMemory(memory, 0, size, .{}) else null;

        return .{
            .buffer = buffer,
            .memory = memory,
            .mapped = mapped,
            .size = size,
        };
    }

    fn allocate(self: *const VulkanRenderer, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
        return try self.dev.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
        }, null);
    }

    fn findMemoryTypeIndex(self: *const VulkanRenderer, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |memory_type, i| {
            if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and memory_type.property_flags.contains(flags)) {
                return @truncate(i);
            }
        }
        return error.NoSuitableMemoryType;
    }

    fn createSwapchain(self: *VulkanRenderer, old_handle: vk.SwapchainKHR) !SwapchainResources {
        const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);
        const extent = findActualExtent(caps, self.windowFramebufferExtent());
        if (extent.width == 0 or extent.height == 0) return error.InvalidSurfaceDimensions;

        const surface_format = try findSurfaceFormat(self, self.allocator);
        const present_mode = try findPresentMode(self, self.allocator);

        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0) image_count = @min(image_count, caps.max_image_count);

        const qfi = [_]u32{ self.graphics_queue.family, self.present_queue.family };
        const sharing_mode: vk.SharingMode = if (self.graphics_queue.family != self.present_queue.family) .concurrent else .exclusive;
        const concurrent = sharing_mode == .concurrent;

        const handle = try self.dev.createSwapchainKHR(&.{
            .surface = self.surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = sharing_mode,
            .queue_family_index_count = if (concurrent) qfi.len else 0,
            .p_queue_family_indices = if (concurrent) &qfi else undefined,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = .true,
            .old_swapchain = old_handle,
        }, null);
        errdefer self.dev.destroySwapchainKHR(handle, null);

        if (old_handle != .null_handle) self.dev.destroySwapchainKHR(old_handle, null);

        const images = try self.dev.getSwapchainImagesAllocKHR(handle, self.allocator);
        defer self.allocator.free(images);

        const image_views = try self.allocator.alloc(vk.ImageView, images.len);
        errdefer self.allocator.free(image_views);

        var initialized: usize = 0;
        errdefer for (image_views[0..initialized]) |view| self.dev.destroyImageView(view, null);

        for (images, image_views) |image, *view_out| {
            view_out.* = try self.dev.createImageView(&.{
                .image = image,
                .view_type = .@"2d",
                .format = surface_format.format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);
            initialized += 1;
        }

        return .{
            .handle = handle,
            .surface_format = surface_format,
            .present_mode = present_mode,
            .extent = extent,
            .min_image_count = @max(caps.min_image_count, 2),
            .image_views = image_views,
        };
    }

    fn recreateSwapchain(self: *VulkanRenderer) !void {
        const requested_extent = self.windowFramebufferExtent();
        if (requested_extent.width == 0 or requested_extent.height == 0) return error.InvalidSurfaceDimensions;

        try self.dev.deviceWaitIdle();

        self.destroySwapchainDependents();
        const old_handle = self.swapchain.handle;
        self.swapchain.destroyImageViews(self);
        self.swapchain = try self.createSwapchain(old_handle);
        try self.createSwapchainDependents();

        if (self.debug_ui_initialized) {
            zgui.backend.set_min_image_count(self.swapchain.min_image_count);
        }
    }

    fn createSwapchainDependents(self: *VulkanRenderer) !void {
        const image_views = self.swapchain.image_views.?;

        self.framebuffers = try self.allocator.alloc(vk.Framebuffer, image_views.len);
        errdefer {
            self.allocator.free(self.framebuffers.?);
            self.framebuffers = null;
        }

        var framebuffer_count: usize = 0;
        errdefer for (self.framebuffers.?[0..framebuffer_count]) |framebuffer| self.dev.destroyFramebuffer(framebuffer, null);

        for (self.framebuffers.?, image_views) |*framebuffer_out, image_view| {
            framebuffer_out.* = try self.dev.createFramebuffer(&.{
                .render_pass = self.render_pass,
                .attachment_count = 1,
                .p_attachments = @ptrCast(&image_view),
                .width = self.swapchain.extent.width,
                .height = self.swapchain.extent.height,
                .layers = 1,
            }, null);
            framebuffer_count += 1;
        }

        self.command_buffers = try self.allocator.alloc(vk.CommandBuffer, image_views.len);
        errdefer {
            self.allocator.free(self.command_buffers.?);
            self.command_buffers = null;
        }
        try self.dev.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(self.command_buffers.?.len),
        }, self.command_buffers.?.ptr);

        self.image_fences = try self.allocator.alloc(vk.Fence, image_views.len);
        @memset(self.image_fences.?, .null_handle);
    }

    fn destroySwapchainDependents(self: *VulkanRenderer) void {
        if (self.command_buffers) |command_buffers| {
            if (self.command_pool != .null_handle) self.dev.freeCommandBuffers(self.command_pool, @intCast(command_buffers.len), command_buffers.ptr);
            self.allocator.free(command_buffers);
            self.command_buffers = null;
        }
        if (self.framebuffers) |framebuffers| {
            for (framebuffers) |framebuffer| self.dev.destroyFramebuffer(framebuffer, null);
            self.allocator.free(framebuffers);
            self.framebuffers = null;
        }
        if (self.image_fences) |image_fences| {
            self.allocator.free(image_fences);
            self.image_fences = null;
        }
    }

    fn createSyncObjects(self: *VulkanRenderer) !void {
        for (0..max_frames_in_flight) |i| {
            self.image_available[i] = try self.dev.createSemaphore(&.{}, null);
            self.render_finished[i] = try self.dev.createSemaphore(&.{}, null);
            self.in_flight_fences[i] = try self.dev.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        }
    }

    fn destroySyncObjects(self: *VulkanRenderer) void {
        for (0..max_frames_in_flight) |i| {
            if (self.image_available[i] != .null_handle) self.dev.destroySemaphore(self.image_available[i], null);
            if (self.render_finished[i] != .null_handle) self.dev.destroySemaphore(self.render_finished[i], null);
            if (self.in_flight_fences[i] != .null_handle) self.dev.destroyFence(self.in_flight_fences[i], null);
        }
    }

    fn createRenderPass(self: *VulkanRenderer, format: vk.Format) !vk.RenderPass {
        const color_attachment = vk.AttachmentDescription{
            .flags = .{},
            .format = format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        };

        const color_attachment_ref = vk.AttachmentReference{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        };

        const subpass = vk.SubpassDescription{
            .flags = .{},
            .pipeline_bind_point = .graphics,
            .input_attachment_count = 0,
            .p_input_attachments = undefined,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment_ref),
            .p_resolve_attachments = null,
            .p_depth_stencil_attachment = null,
            .preserve_attachment_count = 0,
            .p_preserve_attachments = undefined,
        };

        return try self.dev.createRenderPass(&.{
            .flags = .{},
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_attachment),
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 0,
            .p_dependencies = undefined,
        }, null);
    }

    fn framePushConstantRange() vk.PushConstantRange {
        return .{
            .stage_flags = .{ .vertex_bit = true },
            .offset = 0,
            .size = @sizeOf(FrameConstants),
        };
    }

    fn createRectanglePipeline(self: *VulkanRenderer) !vk.Pipeline {
        const binding = vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(RectangleInstance),
            .input_rate = .instance,
        };
        const attributes = [_]vk.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(RectangleInstance, "position") },
            .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(RectangleInstance, "size") },
            .{ .location = 2, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(RectangleInstance, "color") },
        };

        return try self.createGraphicsPipeline(
            rectangle_vert_spv[0..],
            rectangle_frag_spv[0..],
            self.rectangle_pipeline_layout,
            binding,
            attributes[0..],
            false,
        );
    }

    fn createTextDescriptorSetLayout(self: *VulkanRenderer) !vk.DescriptorSetLayout {
        const binding = vk.DescriptorSetLayoutBinding{
            .binding = 0,
            .descriptor_type = .combined_image_sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
            .p_immutable_samplers = null,
        };

        return try self.dev.createDescriptorSetLayout(&.{
            .flags = .{},
            .binding_count = 1,
            .p_bindings = @ptrCast(&binding),
        }, null);
    }

    fn createTextPipelineLayout(self: *VulkanRenderer) !vk.PipelineLayout {
        const frame_constants_range = framePushConstantRange();
        return try self.dev.createPipelineLayout(&.{
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.text_descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&frame_constants_range),
        }, null);
    }

    fn createTextPipeline(self: *VulkanRenderer) !vk.Pipeline {
        const binding = vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(GlyphInstance),
            .input_rate = .instance,
        };
        const attributes = [_]vk.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(GlyphInstance, "position") },
            .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(GlyphInstance, "size") },
            .{ .location = 2, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(GlyphInstance, "uv_min") },
            .{ .location = 3, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(GlyphInstance, "uv_max") },
            .{ .location = 4, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(GlyphInstance, "color") },
        };

        return try self.createGraphicsPipeline(
            text_vert_spv[0..],
            text_frag_spv[0..],
            self.text_pipeline_layout,
            binding,
            attributes[0..],
            true,
        );
    }

    fn createGraphicsPipeline(
        self: *VulkanRenderer,
        vert_spv: []align(@alignOf(u32)) const u8,
        frag_spv: []align(@alignOf(u32)) const u8,
        layout: vk.PipelineLayout,
        binding: vk.VertexInputBindingDescription,
        attributes: []const vk.VertexInputAttributeDescription,
        alpha_blend: bool,
    ) !vk.Pipeline {
        const vert = try self.dev.createShaderModule(&.{
            .flags = .{},
            .code_size = vert_spv.len,
            .p_code = @ptrCast(vert_spv.ptr),
        }, null);
        defer self.dev.destroyShaderModule(vert, null);

        const frag = try self.dev.createShaderModule(&.{
            .flags = .{},
            .code_size = frag_spv.len,
            .p_code = @ptrCast(frag_spv.ptr),
        }, null);
        defer self.dev.destroyShaderModule(frag, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .flags = .{},
                .stage = .{ .vertex_bit = true },
                .module = vert,
                .p_name = "main",
                .p_specialization_info = null,
            },
            .{
                .flags = .{},
                .stage = .{ .fragment_bit = true },
                .module = frag,
                .p_name = "main",
                .p_specialization_info = null,
            },
        };
        const vertex_input = vk.PipelineVertexInputStateCreateInfo{
            .flags = .{},
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&binding),
            .vertex_attribute_description_count = @intCast(attributes.len),
            .p_vertex_attribute_descriptions = attributes.ptr,
        };
        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .flags = .{},
            .topology = .triangle_list,
            .primitive_restart_enable = .false,
        };
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .flags = .{},
            .viewport_count = 1,
            .p_viewports = undefined,
            .scissor_count = 1,
            .p_scissors = undefined,
        };
        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .flags = .{},
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        };
        const multisample = vk.PipelineMultisampleStateCreateInfo{
            .flags = .{},
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };
        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blend_enable = if (alpha_blend) .true else .false,
            .src_color_blend_factor = if (alpha_blend) .src_alpha else .one,
            .dst_color_blend_factor = if (alpha_blend) .one_minus_src_alpha else .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = if (alpha_blend) .one else .one,
            .dst_alpha_blend_factor = if (alpha_blend) .one_minus_src_alpha else .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };
        const color_blend = vk.PipelineColorBlendStateCreateInfo{
            .flags = .{},
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_blend_attachment),
            .blend_constants = [_]f32{ 0, 0, 0, 0 },
        };
        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .flags = .{},
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };
        const pipeline_info = vk.GraphicsPipelineCreateInfo{
            .flags = .{},
            .stage_count = shader_stages.len,
            .p_stages = &shader_stages,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &input_assembly,
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisample,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &color_blend,
            .p_dynamic_state = &dynamic_state,
            .layout = layout,
            .render_pass = self.render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        var pipeline: vk.Pipeline = undefined;
        _ = try self.dev.createGraphicsPipelines(.null_handle, 1, @ptrCast(&pipeline_info), null, @ptrCast(&pipeline));
        return pipeline;
    }

    fn createTextDescriptorPool(self: *VulkanRenderer) !vk.DescriptorPool {
        const pool_size = vk.DescriptorPoolSize{
            .type = .combined_image_sampler,
            .descriptor_count = 1,
        };
        return try self.dev.createDescriptorPool(&.{
            .flags = .{},
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = @ptrCast(&pool_size),
        }, null);
    }

    fn createTextDescriptorSet(self: *VulkanRenderer) !vk.DescriptorSet {
        var descriptor_set: vk.DescriptorSet = undefined;
        try self.dev.allocateDescriptorSets(&.{
            .descriptor_pool = self.text_descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&self.text_descriptor_set_layout),
        }, @ptrCast(&descriptor_set));

        const image_info = vk.DescriptorImageInfo{
            .sampler = self.bitmap_font_texture.sampler,
            .image_view = self.bitmap_font_texture.view,
            .image_layout = .shader_read_only_optimal,
        };
        const write = vk.WriteDescriptorSet{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&image_info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        self.dev.updateDescriptorSets(1, @ptrCast(&write), 0, null);
        return descriptor_set;
    }

    fn createBitmapFontTextureResources(self: *VulkanRenderer) !FontTextureResources {
        const width = default_font_texture_width;
        const height = default_font_texture_height;
        const pixel_count: usize = width * height;
        std.debug.assert(default_font_data.len == default_font_glyph_count);
        std.debug.assert(default_font_data[0].len == default_font_glyph_height);

        const rgba_pixels = try self.allocator.alloc(u8, pixel_count * 4);
        defer self.allocator.free(rgba_pixels);
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

        var staging = try self.createBuffer(
            rgba_pixels.len,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
            true,
        );
        defer staging.deinit(self);

        const staging_bytes: [*]u8 = @ptrCast(@alignCast(staging.mapped.?));
        @memcpy(staging_bytes[0..rgba_pixels.len], rgba_pixels);

        const image = try self.dev.createImage(&.{
            .flags = .{},
            .image_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
            .sharing_mode = .exclusive,
            .queue_family_index_count = 0,
            .p_queue_family_indices = undefined,
            .initial_layout = .undefined,
        }, null);
        errdefer self.dev.destroyImage(image, null);

        const requirements = self.dev.getImageMemoryRequirements(image);
        const memory = try self.allocate(requirements, .{ .device_local_bit = true });
        errdefer self.dev.freeMemory(memory, null);
        try self.dev.bindImageMemory(image, memory, 0);

        try self.uploadFontTexture(image, staging.buffer, width, height);

        const view = try self.dev.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = .r8g8b8a8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer self.dev.destroyImageView(view, null);

        const sampler = try self.dev.createSampler(&.{
            .flags = .{},
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = .false,
        }, null);

        return .{
            .image = image,
            .memory = memory,
            .view = view,
            .sampler = sampler,
        };
    }

    fn uploadFontTexture(self: *VulkanRenderer, image: vk.Image, staging_buffer: vk.Buffer, width: u32, height: u32) !void {
        var command_buffer: vk.CommandBuffer = undefined;
        try self.dev.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer));
        defer self.dev.freeCommandBuffers(self.command_pool, 1, @ptrCast(&command_buffer));

        try self.dev.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

        transitionImageLayout(self.dev, command_buffer, image, .undefined, .transfer_dst_optimal);

        const region = vk.BufferImageCopy{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        };
        self.dev.cmdCopyBufferToImage(command_buffer, staging_buffer, image, .transfer_dst_optimal, 1, @ptrCast(&region));

        transitionImageLayout(self.dev, command_buffer, image, .transfer_dst_optimal, .shader_read_only_optimal);

        try self.dev.endCommandBuffer(command_buffer);

        const submit_info = vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        };
        try self.dev.queueSubmit(self.graphics_queue.handle, 1, @ptrCast(&submit_info), .null_handle);
        try self.dev.queueWaitIdle(self.graphics_queue.handle);
    }

    fn windowFramebufferExtent(self: *const VulkanRenderer) vk.Extent2D {
        const framebuffer_size = self.window.getFramebufferSize();
        return .{
            .width = @intCast(@max(framebuffer_size[0], 0)),
            .height = @intCast(@max(framebuffer_size[1], 0)),
        };
    }
};

const Queue = struct {
    handle: vk.Queue = .null_handle,
    family: u32 = 0,

    fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

const SwapchainResources = struct {
    handle: vk.SwapchainKHR = .null_handle,
    surface_format: vk.SurfaceFormatKHR = undefined,
    present_mode: vk.PresentModeKHR = .fifo_khr,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    min_image_count: u32 = 2,
    image_views: ?[]vk.ImageView = null,

    fn destroyImageViews(self: *SwapchainResources, renderer: *VulkanRenderer) void {
        if (self.image_views) |image_views| {
            for (image_views) |view| renderer.dev.destroyImageView(view, null);
            renderer.allocator.free(image_views);
            self.image_views = null;
        }
    }

    fn deinit(self: *SwapchainResources, renderer: *VulkanRenderer) void {
        self.destroyImageViews(renderer);
        if (self.handle != .null_handle) {
            renderer.dev.destroySwapchainKHR(self.handle, null);
            self.handle = .null_handle;
        }
    }
};

const BufferResource = struct {
    buffer: vk.Buffer = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    mapped: ?*anyopaque = null,
    size: vk.DeviceSize = 0,

    fn deinit(self: *BufferResource, renderer: *VulkanRenderer) void {
        if (self.mapped != null) {
            renderer.dev.unmapMemory(self.memory);
            self.mapped = null;
        }
        if (self.buffer != .null_handle) renderer.dev.destroyBuffer(self.buffer, null);
        if (self.memory != .null_handle) renderer.dev.freeMemory(self.memory, null);
        self.* = .{};
    }
};

const FontTextureResources = struct {
    image: vk.Image = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    view: vk.ImageView = .null_handle,
    sampler: vk.Sampler = .null_handle,

    fn deinit(self: *FontTextureResources, renderer: *VulkanRenderer) void {
        if (self.sampler != .null_handle) renderer.dev.destroySampler(self.sampler, null);
        if (self.view != .null_handle) renderer.dev.destroyImageView(self.view, null);
        if (self.image != .null_handle) renderer.dev.destroyImage(self.image, null);
        if (self.memory != .null_handle) renderer.dev.freeMemory(self.memory, null);
        self.* = .{};
    }
};

fn createInstance(vkb: *const BaseWrapper, allocator: std.mem.Allocator) !vk.Instance {
    var extension_names: std.ArrayList([*:0]const u8) = .empty;
    defer extension_names.deinit(allocator);

    try extension_names.appendSlice(allocator, try zglfw.getRequiredInstanceExtensions());

    const app_info = vk.ApplicationInfo{
        .p_application_name = app_name,
        .application_version = versionToU32(vk.makeApiVersion(0, 0, 0, 0)),
        .p_engine_name = app_name,
        .engine_version = versionToU32(vk.makeApiVersion(0, 0, 0, 0)),
        .api_version = versionToU32(vk.API_VERSION_1_3),
    };

    return try vkb.createInstance(&.{
        .flags = .{},
        .p_application_info = &app_info,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @intCast(extension_names.items.len),
        .pp_enabled_extension_names = extension_names.items.ptr,
    }, null);
}

fn initializeDevice(instance: Instance, candidate: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1};
    const queue_infos = [_]vk.DeviceQueueCreateInfo{
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .flags = .{},
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };
    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family) 1 else 2;

    return try instance.createDevice(candidate.pdev, &.{
        .flags = .{},
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &queue_infos,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        .p_enabled_features = null,
    }, null);
}

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

fn pickPhysicalDevice(instance: Instance, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !DeviceCandidate {
    const devices = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(devices);

    for (devices) |device| {
        if (try checkSuitable(instance, device, allocator, surface)) |candidate| return candidate;
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(instance: Instance, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !?DeviceCandidate {
    if (!try checkDeviceExtensionSupport(instance, pdev, allocator)) return null;
    if (!try checkSurfaceSupport(instance, pdev, surface)) return null;

    if (try allocateQueues(instance, pdev, allocator, surface)) |queues| {
        return .{
            .pdev = pdev,
            .props = instance.getPhysicalDeviceProperties(pdev),
            .queues = queues,
        };
    }

    return null;
}

fn allocateQueues(instance: Instance, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);
        if (graphics_family == null and properties.queue_flags.graphics_bit) graphics_family = family;
        if (present_family == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == .true) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return .{ .graphics_family = graphics_family.?, .present_family = present_family.? };
    }
    return null;
}

fn checkSurfaceSupport(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);
    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);
    return format_count > 0 and present_mode_count > 0;
}

fn checkDeviceExtensionSupport(instance: Instance, pdev: vk.PhysicalDevice, allocator: std.mem.Allocator) !bool {
    const available = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(available);

    for (required_device_extensions) |required| {
        for (available) |extension| {
            if (std.mem.eql(u8, std.mem.span(required), std.mem.sliceTo(&extension.extension_name, 0))) break;
        } else {
            return false;
        }
    }
    return true;
}

fn findSurfaceFormat(renderer: *VulkanRenderer, allocator: std.mem.Allocator) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };
    const formats = try renderer.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(renderer.pdev, renderer.surface, allocator);
    defer allocator.free(formats);

    for (formats) |format| {
        if (std.meta.eql(format, preferred)) return preferred;
    }
    return formats[0];
}

fn findPresentMode(renderer: *VulkanRenderer, allocator: std.mem.Allocator) !vk.PresentModeKHR {
    const modes = try renderer.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(renderer.pdev, renderer.surface, allocator);
    defer allocator.free(modes);

    const preferred = [_]vk.PresentModeKHR{ .mailbox_khr, .immediate_khr };
    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, modes, mode) != null) return mode;
    }
    return .fifo_khr;
}

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != 0xFFFF_FFFF) return caps.current_extent;
    return .{
        .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

fn transitionImageLayout(device: Device, command_buffer: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
    const src_access: vk.AccessFlags = if (old_layout == .undefined) .{} else .{ .transfer_write_bit = true };
    const dst_access: vk.AccessFlags = if (new_layout == .transfer_dst_optimal) .{ .transfer_write_bit = true } else .{ .shader_read_bit = true };
    const src_stage: vk.PipelineStageFlags = if (old_layout == .undefined) .{ .top_of_pipe_bit = true } else .{ .transfer_bit = true };
    const dst_stage: vk.PipelineStageFlags = if (new_layout == .transfer_dst_optimal) .{ .transfer_bit = true } else .{ .fragment_shader_bit = true };

    const barrier = vk.ImageMemoryBarrier{
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    device.cmdPipelineBarrier(command_buffer, src_stage, dst_stage, .{}, 0, null, 0, null, 1, @ptrCast(&barrier));
}

fn getGlfwInstanceProcAddr(instance: vk.Instance, procname: [*:0]const u8) vk.PfnVoidFunction {
    return @ptrCast(zglfw.getInstanceProcAddress(instance, procname));
}

fn loadZguiVulkanFunction(function_name: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self: *VulkanRenderer = @ptrCast(@alignCast(user_data.?));
    const function = zglfw.getInstanceProcAddress(self.instance.handle, function_name) orelse return null;
    return @ptrCast(@constCast(function));
}

fn imguiHandle(handle: anytype) zgui.backend.VkHandle {
    const value = @intFromEnum(handle);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(value)));
}

fn versionToU32(version: vk.Version) u32 {
    return @bitCast(version);
}

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
