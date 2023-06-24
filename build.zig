const std = @import("std");
// XXX: don't merge until build system PR (or alternative) is merged)
// XXX: move into engine?
// XXX: does deleting stuff update the build properly?
const BakeAssets = @import("src/bake/BakeAssets.zig");
const Allocator = std.mem.Allocator;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // XXX: I think I want separate build scripts for the game, engine, other games, this is
    // gonna get too hard to follow quickly otherwise
    const exe = b.addExecutable(.{
        .name = "pew",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/game/src/game.zig" },
        .target = target,
        .optimize = optimize,
    });

    const use_llvm = b.option(bool, "use-llvm", "use zig's llvm backend");
    exe.use_llvm = use_llvm;
    exe.use_lld = use_llvm;

    // https://github.com/MasonRemaley/2Pew/issues/2
    exe.want_lto = false;

    var engine = b.createModule(.{
        .source_file = .{ .path = "src/engine/engine.zig" },
    });
    exe.addModule("engine", engine);

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

    // Bake images
    var bake_images = BakeAssets.create(b);
    defer bake_images.deinit();
    try bake_images.addAssets("src/game/data", ".png", .install, .{
        .exe = exe: {
            var bake_image = b.addExecutable(.{
                .name = "bake-image",
                .root_source_file = .{ .path = "src/game/bake/bake_image.zig" },
                // XXX: ...
                .target = target,
                .optimize = optimize,
            });
            bake_image.addCSourceFile("src/game/bake/stb_image.c", &.{"-std=c99"});
            bake_image.addIncludePath("src/game/bake");
            bake_image.linkLibC();
            break :exe bake_image;
        },
        // XXX: don't include the . in these, make it automatic, so you can't leave it off
        .output_extension = ".sprite",
    });
    exe.addModule("image_descriptors", try bake_images.createModule());

    // XXX: make sure to make the win/header particle able to be tinted! we could also just set this
    // per sprite instance instead of per sprite asset and have it be the mask or not that's set on the
    // instance, idk.
    // XXX: maybe check that no .sprite.pngs are references from .sprite.zigs since that's probably a mistake?
    // Bake sprites
    var bake_sprites = BakeAssets.create(b);
    defer bake_sprites.deinit();
    try bake_sprites.addAssets("src/game/data", ".sprite.png", .import, .{
        .exe = b.addExecutable(.{
            .name = "bake-sprite",
            .root_source_file = .{ .path = "src/game/bake/bake_sprite_png.zig" },
            // XXX: ...
            .target = target,
            .optimize = optimize,
        }),
        .output_extension = ".sprite.zig",
    });
    // XXX: add a baker for verification purposes: check image sizes, check that we don't depend on a .sprite.png since that's probably a mistake. note that we only need to load the header to check sizes!
    // To do that though, we need to be able to read the zig file from zig, which we can't currently do. So either it needs to be json
    // that gets converted to zig, or, we need to figure out zon. zon is a much more attractive option.
    // XXX: need to auto create the json files if missing...also need to depend on them properly so changing them
    // triggers rebuilds when needed! and need to error on unused fields if the bake exe doesn't use them etc or require
    // it use them idk
    // XXX: too many extensions is annoying...just have one and require unique/add or modify to be .zig when needed?
    // XXX: why are we outputting .sprite.sprite files..?
    try bake_sprites.addAssets("src/game/data", ".sprite.zig", .import, null);
    exe.addModule("sprite_descriptors", try bake_sprites.createModule());

    // Bake animations
    var bake_animations = BakeAssets.create(b);
    defer bake_animations.deinit();
    try bake_animations.addAssets("src/game/data", ".anim.zig", .import, null);
    exe.addModule("animation_descriptors", try bake_animations.createModule());

    // Creates a step for unit testing.
    const game_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/game/src/game.zig" },
        .target = target,
        .optimize = optimize,
    });
    const engine_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/engine/engine.zig" },
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
    const run_game_tests = b.addRunArtifact(game_tests);
    const run_engine_tests = b.addRunArtifact(engine_tests);
    test_step.dependOn(&run_game_tests.step);
    test_step.dependOn(&run_engine_tests.step);
}
