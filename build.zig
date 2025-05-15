const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_llvm = b.option(
        bool,
        "no-llvm",
        "Don't use the LLVM backend.",
    ) orelse false;

    // Allow the user to enable or disable Tracy support with a build flag
    const tracy_enabled = b.option(
        bool,
        "tracy",
        "Build with Tracy support.",
    ) orelse false;

    const exe = b.addExecutable(.{
        .name = "pew",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = !no_llvm,
    });

    const zcs = b.dependency("zcs", .{
        .optimize = optimize,
        .target = target,
    });
    exe.root_module.addImport("zcs", zcs.module("zcs"));

    const build_zig_zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("build.zig.zon", build_zig_zon);

    const gpu = b.dependency("gpu", .{
        .optimize = optimize,
        .target = target,
    });
    exe.root_module.addImport("gpu", gpu.module("gpu"));
    exe.root_module.addImport("VkBackend", gpu.module("VkBackend"));

    const logger = b.dependency("logger", .{
        .optimize = optimize,
        .target = target,
    });
    exe.root_module.addImport("logger", logger.module("logger"));

    const structopt = b.dependency("structopt", .{
        .optimize = optimize,
        .target = target,
    });
    exe.root_module.addImport("structopt", structopt.module("structopt"));

    // Get the Tracy dependency
    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    });

    // Make Tracy available as an import
    exe.root_module.addImport("tracy", tracy.module("tracy"));

    // Pick an implementation based on the build flags.
    // Don't build both, we don't want to link with Tracy at all unless we intend to enable it.
    if (tracy_enabled) {
        // The user asked to enable Tracy, use the real implementation
        exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
    } else {
        // The user asked to disable Tracy, use the dummy implementation
        exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
    }

    const use_llvm = b.option(bool, "use-llvm", "use zig's llvm backend");
    exe.use_llvm = use_llvm;
    exe.use_lld = use_llvm;

    // https://github.com/MasonRemaley/2Pew/issues/2
    exe.want_lto = false;

    if (target.query.isNativeOs()) {
        // The SDL package doesn't work for Linux yet, so we rely on system
        // packages for now.
        exe.linkSystemLibrary("SDL2");
        exe.linkLibC();
    } else {
        @panic("unimplemented");
    }

    // TODO extract this into a proper zig package
    exe.addCSourceFile(.{
        .file = b.path("src/stb_image.c"),
        .flags = &.{"-std=c99"},
    });
    exe.addIncludePath(b.path("src"));

    b.installDirectory(.{
        .source_dir = b.path("data"),
        .install_dir = .prefix,
        .install_subdir = "data",
    });

    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .prefix },
    }).step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = !no_llvm,
    });
    const bench_step = b.step("bench", "Run benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);

    const check_step = b.step("check", "Check the build");
    check_step.dependOn(&exe_tests.step);
    check_step.dependOn(&exe.step);
}
