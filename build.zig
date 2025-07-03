const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_step_target = b.resolveTargetQuery(.{});

    // Allow the user to enable or disable Tracy support with a build flag
    const tracy_enabled = b.option(
        bool,
        "tracy",
        "Build with Tracy support.",
    ) orelse false;

    const force_llvm = b.option(
        bool,
        "llvm",
        "Force the LLVM backend.",
    ) orelse tracy_enabled; // https://github.com/Games-by-Mason/tracy_zig/issues/12

    const exe = b.addExecutable(.{
        .name = "pew",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (force_llvm) {
        exe.use_llvm = true;
        exe.use_lld = true;
    }

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

    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("tracy", tracy.module("tracy"));
    if (tracy_enabled) {
        exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_enabled"));
    } else {
        exe.root_module.addImport("tracy_impl", tracy.module("tracy_impl_disabled"));
    }

    // https://github.com/MasonRemaley/2Pew/issues/2
    exe.want_lto = false;

    const sdl = b.dependency("sdl", .{
        .optimize = optimize,
        .target = target,
    });
    exe.linkLibrary(sdl.artifact("SDL3"));

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

    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .prefix },
    });
    b.getInstallStep().dependOn(&install_exe.step);

    const shader_compiler = b.dependency("shader_compiler", .{
        .target = build_step_target,
        .optimize = .ReleaseSafe,
    });
    const shader_compiler_exe = shader_compiler.artifact("shader_compiler");

    const install_shaders_step = b.step("shaders", "Build and install the shaders");
    b.getInstallStep().dependOn(install_shaders_step);
    installShaderProgram(
        b,
        install_shaders_step,
        shader_compiler_exe,
        "ecs.vf.glsl",
        optimize,
    );
    installShaderProgram(
        b,
        install_shaders_step,
        shader_compiler_exe,
        "ecs.vf.glsl",
        optimize,
    );
    installShaderProgram(
        b,
        install_shaders_step,
        shader_compiler_exe,
        "kawase_blur.comp.glsl",
        optimize,
    );
    installShaderProgram(
        b,
        install_shaders_step,
        shader_compiler_exe,
        "composite.comp.glsl",
        optimize,
    );

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = !force_llvm,
    });
    const bench_step = b.step("bench", "Run benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    const check_step = b.step("check", "Check the build");
    check_step.dependOn(&exe_tests.step);
    check_step.dependOn(&exe.step);
}

fn installShaderProgram(
    b: *std.Build,
    install_shaders_step: *std.Build.Step,
    exe: *std.Build.Step.Compile,
    path: []const u8,
    optimize: std.builtin.OptimizeMode,
) void {
    const filename = std.fs.path.basename(path);
    var iter = std.mem.splitScalar(u8, filename, '.');
    const name = iter.next().?;
    const stages_str = iter.next().?;
    std.debug.assert(std.mem.eql(u8, iter.next().?, "glsl"));
    std.debug.assert(iter.next() == null);

    const stages = std.StaticStringMap(enum { vf, comp }).initComptime(.{
        .{ "vf", .vf },
        .{ "comp", .comp },
    }).get(stages_str) orelse std.debug.panic("unknown shader stages {s}", .{stages_str});

    switch (stages) {
        .vf => {
            installShader(b, install_shaders_step, exe, .vert, name, path, optimize);
            installShader(b, install_shaders_step, exe, .frag, name, path, optimize);
        },
        .comp => {
            installShader(b, install_shaders_step, exe, .comp, name, path, optimize);
        },
    }
}

fn installShader(
    b: *std.Build,
    install_shaders_step: *std.Build.Step,
    exe: *std.Build.Step.Compile,
    stage: enum { vert, frag, comp },
    name: []const u8,
    path: []const u8,
    optimize: std.builtin.OptimizeMode,
) void {
    const compile_shader = b.addRunArtifact(exe);

    // We just always include debug info for now, it's useful to have when something goes wrong and
    // I don't expect the shaders to be particularly large. I also don't mind sharing the source to
    // them etc.
    compile_shader.addArg("--debug");

    compile_shader.addArgs(&.{ "--stage", @tagName(stage) });

    compile_shader.addArg("--preamble");
    compile_shader.addFileArg(b.path(b.pathJoin(&.{ "src", "shaders", "preamble.glsl" })));

    compile_shader.addArgs(&.{ "--default-version", "460" });

    compile_shader.addArg("--scalar-block-layout");

    compile_shader.addArgs(&.{ "--target", "Vulkan-1.3" });

    compile_shader.addArg("--include-path");
    compile_shader.addDirectoryArg(b.path("src/shaders"));

    const gbms = b.dependency("gbms", .{});
    compile_shader.addArg("--include-path");
    compile_shader.addDirectoryArg(gbms.path("include"));

    compile_shader.addArg("--write-deps");
    _ = compile_shader.addDepFileOutputArg("deps.d");

    switch (optimize) {
        .Debug, .ReleaseSafe => compile_shader.addArgs(&.{ "--define", "RUNTIME_SAFETY=1" }),
        .ReleaseFast, .ReleaseSmall => compile_shader.addArgs(&.{ "--define", "RUNTIME_SAFETY=0" }),
    }

    switch (optimize) {
        .Debug, .ReleaseSafe => {},
        .ReleaseFast => compile_shader.addArg("--optimize-perf"),
        .ReleaseSmall => compile_shader.addArgs(&.{
            "--optimize-perf",
            "--optimize-size",
        }),
    }
    compile_shader.addFileArg(b.path(b.pathJoin(&.{ "src", "shaders", path })));

    const spv = compile_shader.addOutputFileArg("compiled.spv");

    const file = b.addInstallFile(spv, b.pathJoin(&.{
        "data",
        "shaders",
        b.fmt("{s}.{s}.spv", .{ name, @tagName(stage) }),
    }));

    install_shaders_step.dependOn(&file.step);
}
