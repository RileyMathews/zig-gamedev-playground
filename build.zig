const std = @import("std");
const builtin = @import("builtin");

const RendererBackend = enum {
    zgpu,
    vulkan,
};

pub fn build(b: *std.Build) void {
    // Zig 0.15.x's native Linux target currently tries to link this machine's
    // GCC 16 crt1.o, whose .sframe relocations are not handled by Zig's linker.
    // Defaulting to an explicit host arch/OS/ABI target keeps plain `zig build`
    // working while still allowing `-Dtarget=...` overrides.
    const target = b.standardTargetOptions(.{ .default_target = defaultTarget() });
    const optimize = b.standardOptimizeOption(.{});
    const renderer_backend = b.option(RendererBackend, "renderer", "Renderer backend to build (default: zgpu)") orelse .zgpu;

    const exe = b.addExecutable(.{
        .name = "zig_gamedev_playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const vulkan_headers = if (renderer_backend == .vulkan)
        b.lazyDependency("vulkan_headers", .{}) orelse @panic("vulkan_headers dependency is required for -Drenderer=vulkan")
    else
        null;
    const vulkan = if (renderer_backend == .vulkan)
        (b.lazyDependency("vulkan", .{
            .registry = vulkan_headers.?.path("registry/vk.xml"),
        }) orelse @panic("vulkan dependency is required for -Drenderer=vulkan")).module("vulkan-zig")
    else
        null;

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
        .import_vulkan = renderer_backend == .vulkan,
    });
    const zglfw_mod = zglfw.module("root");
    if (vulkan) |vulkan_mod| {
        zglfw_mod.addImport("vulkan", vulkan_mod);
    }
    exe.root_module.addImport("zglfw", zglfw_mod);
    if (target.result.os.tag != .emscripten) {
        exe.linkLibrary(zglfw.artifact("glfw"));
    }

    const zgui = switch (renderer_backend) {
        .zgpu => b.dependency("zgui", .{
            .target = target,
            .optimize = optimize,
            .backend = .glfw_wgpu,
        }),
        .vulkan => b.dependency("zgui", .{
            .target = target,
            .optimize = optimize,
            .backend = .glfw_vulkan,
            .vulkan_include = vulkan_headers.?.path("include").getPath2(b, null),
        }),
    };
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    const renderer_mod = b.createModule(.{
        .root_source_file = b.path(switch (renderer_backend) {
            .zgpu => "src/renderers/zgpu/renderer.zig",
            .vulkan => "src/renderers/vulkan/renderer.zig",
        }),
        .target = target,
        .optimize = optimize,
    });
    renderer_mod.addImport("zglfw", zglfw_mod);
    renderer_mod.addImport("zgui", zgui.module("root"));

    switch (renderer_backend) {
        .zgpu => {
            const zgpu = b.dependency("zgpu", .{
                .target = target,
                .optimize = optimize,
            });
            const zgpu_mod = zgpu.module("root");
            exe.root_module.addImport("zgpu", zgpu_mod);
            renderer_mod.addImport("zgpu", zgpu_mod);
            @import("zgpu").addLibraryPathsTo(exe);
            exe.linkLibrary(zgpu.artifact("zdawn"));
        },
        .vulkan => {
            renderer_mod.addImport("vulkan", vulkan.?);
            addVulkanShaders(b, renderer_mod);
        },
    }

    exe.root_module.addImport("renderer", renderer_mod);

    if (target.result.os.tag == .linux) {
        const system_sdk = b.dependency("system_sdk", .{});
        exe.addLibraryPath(system_sdk.path("linux/lib/x86_64-linux-gnu"));
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the default executable");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

fn addVulkanShaders(b: *std.Build, renderer_mod: *std.Build.Module) void {
    addGlslShader(b, renderer_mod, "rectangle_vertex_shader", "src/renderers/vulkan/rectangle.vert", "rectangle.vert.spv");
    addGlslShader(b, renderer_mod, "rectangle_fragment_shader", "src/renderers/vulkan/rectangle.frag", "rectangle.frag.spv");
    addGlslShader(b, renderer_mod, "text_vertex_shader", "src/renderers/vulkan/text.vert", "text.vert.spv");
    addGlslShader(b, renderer_mod, "text_fragment_shader", "src/renderers/vulkan/text.frag", "text.frag.spv");
}

fn addGlslShader(
    b: *std.Build,
    renderer_mod: *std.Build.Module,
    comptime import_name: []const u8,
    shader_path: []const u8,
    output_name: []const u8,
) void {
    const cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.2",
        "-o",
    });
    const spv = cmd.addOutputFileArg(output_name);
    cmd.addFileArg(b.path(shader_path));
    renderer_mod.addAnonymousImport(import_name, .{ .root_source_file = spv });
}

fn defaultTarget() std.Target.Query {
    return .{
        .cpu_arch = builtin.target.cpu.arch,
        .os_tag = builtin.target.os.tag,
        .abi = builtin.target.abi,
    };
}
