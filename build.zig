// XXX: baking todo
// - inline switch in zon instead of for loop on indices?
// - move build code into engine?
// - does deleting stuff update the build properly?
// - says installing while running...
// - separate build scripts for seaparate sub projects, too confusing otherwise
// - is the output less confusing if we rename extensions or can there be collisions one way or the other?
// - wait cross target should just be this target for the bake step right?
// - don't include the . in extension args, make it automatic, so you can't leave it off
// - creating bake steps is very verbose...
// - force verificaiton of all zon at bake time?
// - get embedding working again (need to be able to import zon first)
// - auto create the id files, rename to id, possibly just have id in them?
// - report good errors on zon stuff (test error handling api in practice!)
const std = @import("std");
const BakeAssets = @import("src/bake/BakeAssets.zig");
const Allocator = std.mem.Allocator;
const FileSource = std.Build.FileSource;
const zon = @import("zon").zon;

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

    const zon_module = b.dependency("zon", .{ .target = target, .optimize = .ReleaseFast }).module("zon");

    const pew_exe = b.addExecutable(.{
        .name = "pew",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/game/src/game.zig" },
        .target = target,
        .optimize = optimize,
    });

    var engine = b.createModule(.{
        .source_file = .{ .path = "src/engine/engine.zig" },
    });
    pew_exe.addModule("engine", engine);
    pew_exe.addModule("zon", zon_module);

    const use_llvm = b.option(bool, "use-llvm", "use zig's llvm backend");
    pew_exe.use_llvm = use_llvm;
    pew_exe.use_lld = use_llvm;

    // https://github.com/MasonRemaley/2Pew/issues/2
    pew_exe.want_lto = false;

    if (target.isNativeOs() and target.getOsTag() == .linux) {
        // The SDL package doesn't work for Linux yet, so we rely on system
        // packages for now.
        pew_exe.linkSystemLibrary("SDL2");
        pew_exe.linkLibC();
    } else {
        const zig_sdl = b.dependency("zig_sdl", .{
            .target = target,
            .optimize = .ReleaseFast,
        });
        pew_exe.linkLibrary(zig_sdl.artifact("SDL2"));
    }

    pew_exe.override_dest_dir = .prefix;
    b.installArtifact(pew_exe);

    // This *creates* a RunStep in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(pew_exe);

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

    const data_path = "src/game/data";

    // Bake sprites
    const bake_sprite_exe = b: {
        const exe = b.addExecutable(.{
            .name = "bake-sprite",
            .root_source_file = .{ .path = "src/game/bake/bake_sprite.zig" },
            .target = target,
            .optimize = optimize,
        });
        exe.addCSourceFile("src/game/bake/stb_image.c", &.{"-std=c99"});
        exe.addIncludePath("src/game/bake");
        exe.linkLibC();
        break :b exe;
    };
    const BakeSpritePng = struct {
        const Self = @This();

        owner: *std.Build,
        exe: *std.Build.CompileStep,

        fn create(owner: *std.Build, exe: *std.Build.CompileStep) Self {
            return .{
                .owner = owner,
                .exe = exe,
            };
        }

        fn run(ctx: *const anyopaque, args: BakeAssets.BakeStep.RunArgs) !BakeAssets.BakeStep.Baked {
            const self: *const Self = @ptrCast(@alignCast(ctx));

            const process = self.owner.addRunArtifact(self.exe);
            process.setName(try std.fmt.allocPrint(self.owner.allocator, "{s} ({s})", .{
                process.step.name,
                args.asset_path,
            }));

            // Add an argument for the diffuse image
            // XXX: use add relative?
            const asset_cached = args.cache_input.addCopyFile(.{ .path = args.asset_path }, args.asset_path);
            process.addFileSourceArg(asset_cached);

            // Add an argument for the tint
            process.addArg("none");

            // Add an argument for the rotation
            process.addArg("0");

            // Add an argument for the out path
            const out_path = try std.fmt.allocPrint(
                self.owner.allocator,
                "{s}.sprite",
                .{args.default_install_path},
            );
            return .{
                .file_source = process.addOutputFileArg(out_path),
                .install_path = out_path,
            };
        }

        pub fn bakeStep(self: *const @This()) BakeAssets.BakeStep {
            return .{
                .ptr = self,
                .vtable = &.{ .run = run },
            };
        }
    };
    const bake_sprite_png = BakeSpritePng.create(b, bake_sprite_exe);
    var bake_sprites = BakeAssets.create(b);
    defer bake_sprites.deinit();
    try bake_sprites.addAssets(.{
        .path = data_path,
        .extension = ".sprite.png",
        .storage = .install,
        .bake_step = bake_sprite_png.bakeStep(),
    });
    const BakeSpriteZon = struct {
        const Self = @This();

        exe: *std.Build.CompileStep,

        const Tint = union(enum) {
            none,
            luminosity,
            mask: []const u8,
        };

        const Sprite = struct {
            diffuse: []const u8,
            degrees: f32 = 0.0,
            tint: Tint = .none,
        };

        fn create(exe: *std.Build.CompileStep) Self {
            return .{
                .exe = exe,
            };
        }

        fn run(ctx: *const anyopaque, args: BakeAssets.BakeStep.RunArgs) !BakeAssets.BakeStep.Baked {
            const self: *const Self = @ptrCast(@alignCast(ctx));

            const process = self.exe.step.owner.addRunArtifact(self.exe);
            process.setName(try std.fmt.allocPrint(self.exe.step.owner.allocator, "{s} ({s})", .{
                process.step.name,
                args.asset_path,
            }));

            // Read the sprite definition
            const sprite = b: {
                var zon_source = try self.exe.step.owner.build_root.handle.readFileAllocOptions(
                    self.exe.step.owner.allocator,
                    args.asset_path,
                    1024,
                    null,
                    @alignOf(u8),
                    0,
                );
                defer self.exe.step.owner.allocator.free(zon_source);

                break :b try zon.parseFromSlice(Sprite, self.exe.step.owner.allocator, zon_source, .{});
            };
            defer zon.parseFree(self.exe.step.owner.allocator, sprite);

            // Add an argument for the diffuse image
            {
                var diffuse_path = try std.fs.path.join(self.exe.step.owner.allocator, &.{
                    std.fs.path.dirname(args.asset_path).?,
                    sprite.diffuse,
                });
                // defer self.exe.step.owner.allocator.free(diffuse_path); // XXX: ...
                var diffuse_cached = args.cache_input.addCopyFile(
                    .{ .path = diffuse_path },
                    diffuse_path,
                );
                process.addFileSourceArg(diffuse_cached);
            }

            // Add an argument for the tint
            switch (sprite.tint) {
                .mask => |path_rel| {
                    var mask_path = try std.fs.path.join(self.exe.step.owner.allocator, &.{
                        std.fs.path.dirname(args.asset_path).?,
                        path_rel,
                    });
                    // defer self.exe.step.owner.allocator.free(mask_path); // XXX: ...
                    var mask_cached = args.cache_input.addCopyFile(
                        .{ .path = mask_path },
                        mask_path,
                    );
                    process.addFileSourceArg(mask_cached);
                },
                .none => process.addArg("none"),
                .luminosity => process.addArg("luminosity"),
            }

            // Add an argument for the rotation
            {
                // XXX: a little silly to parse from string to f32 and then back to string, maybe
                // the tricks josh is using to allow for more flexible json parsing would be useful in a small way here?
                var degrees = try std.fmt.allocPrint(self.exe.step.owner.allocator, "{}", .{sprite.degrees});
                defer self.exe.step.owner.allocator.free(degrees);
                process.addArg(degrees);
            }

            // Add an argument for the out path
            const out_path = try std.fmt.allocPrint(
                self.exe.step.owner.allocator,
                "{s}.sprite",
                .{args.default_install_path},
            );
            return .{
                .file_source = process.addOutputFileArg(out_path),
                .install_path = out_path,
            };
        }

        pub fn bakeStep(self: *const @This()) BakeAssets.BakeStep {
            return .{
                .ptr = self,
                .vtable = &.{ .run = run },
            };
        }
    };
    var bake_sprite_zon = BakeSpriteZon.create(bake_sprite_exe);
    // XXX: make sure that missing mask files and such get good errors...
    try bake_sprites.addAssets(.{
        .path = data_path,
        .extension = ".sprite.zon",
        .storage = .install,
        .bake_step = bake_sprite_zon.bakeStep(),
    });
    pew_exe.addModule("sprite_descriptors", try bake_sprites.createModule());

    // Bake animations
    var bake_animations = BakeAssets.create(b);
    defer bake_animations.deinit();
    try bake_animations.addAssets(.{
        .path = data_path,
        .extension = ".anim.zon",
        .storage = .install,
    });
    pew_exe.addModule("animation_descriptors", try bake_animations.createModule());

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
