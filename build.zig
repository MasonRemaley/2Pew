const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "pew",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const use_llvm = b.option(bool, "use-llvm", "use zig's llvm backend");
    exe.use_llvm = use_llvm;
    exe.use_lld = use_llvm;

    // https://github.com/MasonRemaley/2Pew/issues/2
    exe.want_lto = false;

    if (target.isNativeOs() and target.getOsTag() == .linux) {
        // The SDL package doesn't work for Linux yet, so we rely on system
        // packages for now.
        exe.linkSystemLibrary("SDL2");
        exe.linkLibC();
    } else {
        const zig_sdl = b.dependency("zig_sdl", .{
            .target = target,
            .optimize = .ReleaseFast,
        });
        exe.linkLibrary(zig_sdl.artifact("SDL2"));
    }

    // TODO extract this into a proper zig package
    exe.addCSourceFile("src/stb_image.c", &.{"-std=c99"});
    exe.addIncludePath("src");

    // XXX: right now this installs some data that's no longer needed at runtime, that won't be true
    // once we create the bake step, this also may not need to be in src then
    b.installDirectory(.{
        .source_dir = "src/data",
        .install_dir = .prefix,
        .install_subdir = "data",
    });

    exe.override_dest_dir = .prefix;
    b.installArtifact(exe);

    // This *creates* a RunStep in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // XXX: pull out into its own step or something that we can just call from here!
    // XXX: eventually do baking of things like tints here
    // XXX: allow asset groups for purposes of choosing random versions of things? e.g. an artist can
    // add a file to a group via a config file or folder structure, and it shows up in game without the
    // game needing to modify internal arrays of things. may also be useful for things like animations?
    // XXX: asset packs for loading groups of assets together? (and verifying they exist?) if we make some of
    // this dynamic instead of static we may want the missing asset fallbacks again?
    // XXX: allow speicfying the same input asset with different bake settings multiple times?
    // XXX: what about e.g. deleting an asset that wasn't yet released? we could have a way to mark them as such maye idk, on release
    // it can change whether they need to be persistent
    // {
    //     const bake_exe = b.addExecutable(.{
    //         .name = "bake",
    //         .root_source_file = .{ .path = "bake/main.zig" },
    //         // XXX: set these?
    //         .target = target,
    //         .optimize = optimize,
    //     });

    //     const bake_run = b.addRunArtifact(bake_exe);
    //     const baked_output = bake_run.addOutputFileArg("baked.zig");

    //     const bake_write = b.addWriteFiles();
    //     bake_write.addCopyFileToSource(baked_output, "src/baked.zig");
    //     bake_write.step.dependOn(&bake_run.step);

    //     const bake_step = b.step("bake", "Bake the data files");
    //     bake_step.dependOn(&bake_write.step);

    //     exe.step.dependOn(bake_step);
    // }

    // Creates a step for unit testing.
    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = .{ .path = "src/bench.zig" },
        .target = target,
        .optimize = optimize,
    });
    bench_exe.override_dest_dir = .prefix;
    const bench_step = b.step("bench", "Run benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
