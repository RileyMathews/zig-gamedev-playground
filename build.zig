const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Zig 0.15.x's native Linux target currently tries to link this machine's
    // GCC 16 crt1.o, whose .sframe relocations are not handled by Zig's linker.
    // Defaulting to an explicit host arch/OS/ABI target keeps plain `zig build`
    // working while still allowing `-Dtarget=...` overrides.
    const target = b.standardTargetOptions(.{ .default_target = defaultTarget() });
    const optimize = b.standardOptimizeOption(.{});
    const enable_ztracy = b.option(bool, "enable_ztracy", "Enable Tracy profile markers") orelse false;

    const exe = b.addExecutable(.{
        .name = "zig_gamedev_playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan = b.dependency("vulkan", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    }).module("vulkan-zig");

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
        .import_vulkan = true,
    });
    const zglfw_mod = zglfw.module("root");
    zglfw_mod.addImport("vulkan", vulkan);
    exe.root_module.addImport("zglfw", zglfw_mod);
    if (target.result.os.tag != .emscripten) {
        exe.linkLibrary(zglfw.artifact("glfw"));
    }

    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw_vulkan,
        .vulkan_include = vulkan_headers.path("include").getPath2(b, null),
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    const ztracy = b.dependency("ztracy", .{
        .target = target,
        .optimize = optimize,
        .enable_ztracy = enable_ztracy,
    });
    const tracy = ztracy.artifact("tracy");
    tracy.root_module.addCMacro("TRACY_NO_CALLSTACK", "");
    exe.root_module.addImport("ztracy", ztracy.module("root"));
    exe.linkLibrary(tracy);

    const renderer_mod = b.createModule(.{
        .root_source_file = b.path("src/renderers/vulkan/renderer.zig"),
        .target = target,
        .optimize = optimize,
    });
    renderer_mod.addImport("zglfw", zglfw_mod);
    renderer_mod.addImport("zgui", zgui.module("root"));
    renderer_mod.addImport("vulkan", vulkan);
    addVulkanShaders(b, renderer_mod);

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
