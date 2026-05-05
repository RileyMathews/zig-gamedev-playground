const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Zig 0.15.x's native Linux target currently tries to link this machine's
    // GCC 16 crt1.o, whose .sframe relocations are not handled by Zig's linker.
    // Defaulting to an explicit host arch/OS/ABI target keeps plain `zig build`
    // working while still allowing `-Dtarget=...` overrides.
    const target = b.standardTargetOptions(.{ .default_target = defaultTarget() });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig_gamedev_playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));
    if (target.result.os.tag != .emscripten) {
        exe.linkLibrary(zglfw.artifact("glfw"));
    }

    const zgpu = b.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zgpu", zgpu.module("root"));
    @import("zgpu").addLibraryPathsTo(exe);
    exe.linkLibrary(zgpu.artifact("zdawn"));

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

fn defaultTarget() std.Target.Query {
    return .{
        .cpu_arch = builtin.target.cpu.arch,
        .os_tag = builtin.target.os.tag,
        .abi = builtin.target.abi,
    };
}
