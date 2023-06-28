const std = @import("std");
// XXX: don't merge until build system PR (or alternative) is merged)
// XXX: move into engine?
// XXX: does deleting stuff update the build properly?
// XXX: says installing while running lol...
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

    // XXX: I think I want separate build scripts for the game, engine, other games, this is
    // gonna get too hard to follow quickly otherwise
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

    // Bake images
    const data_path = "src/game/data";
    const BakeImage = struct {
        const Self = @This();

        owner: *std.Build,
        exe: *std.Build.CompileStep,

        // XXX: wait cross target should just be this target for the bake step right?
        fn create(owner: *std.Build, t: std.zig.CrossTarget, o: std.builtin.Mode) Self {
            var exe = owner.addExecutable(.{
                .name = "bake-image",
                .root_source_file = .{ .path = "src/game/bake/bake_image.zig" },
                // XXX: ... re-getting because variables not available..
                .target = t,
                .optimize = o,
            });
            exe.addCSourceFile("src/game/bake/stb_image.c", &.{"-std=c99"});
            exe.addIncludePath("src/game/bake");
            exe.linkLibC();
            return .{ .owner = owner, .exe = exe };
        }

        // XXX: any way to make the anyopaque cast automatic? see articles about zig interfaces?
        // XXX: return arg naming...
        // XXX: what are all these args..??
        fn run(ctx: *const anyopaque, args: BakeAssets.BakeStep.RunArgs) !?BakeAssets.BakeStep.BakedAsset {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            const baked_asset_path_out = try std.fmt.allocPrint(self.owner.allocator, "{s}.pimg", .{args.asset_path_out});
            const process = self.owner.addRunArtifact(self.exe);
            process.addFileSourceArg(args.asset_cached);
            const file_source = process.addOutputFileArg(baked_asset_path_out);
            return .{
                .file_source = file_source,
                .asset_path_out = baked_asset_path_out,
            };
        }

        pub fn bakeStep(self: *const @This()) BakeAssets.BakeStep {
            return .{
                .ptr = self,
                .vtable = &.{ .run = run },
            };
        }
    };

    const bake_image = BakeImage.create(b, target, optimize);
    var bake_images = BakeAssets.create(b);
    defer bake_images.deinit();
    try bake_images.addAssets(.{
        .path = data_path,
        .extension = ".png",
        .storage = .install,
        .bake_step = bake_image.bakeStep(),
    });
    // XXX: don't include the . in extension args, make it automatic, so you can't leave it off
    pew_exe.addModule("image_descriptors", try bake_images.createModule());

    // XXX: make sure to make the win/header particle able to be tinted! we could also just set this
    // per sprite instance instead of per sprite asset and have it be the mask or not that's set on the
    // instance, idk.
    // XXX: maybe check that no .sprite.pngs are references from .sprite.zigs since that's probably a mistake?
    // Bake sprites
    const BakeSpritePng = struct {
        const Self = @This();

        owner: *std.Build,
        exe: *std.Build.CompileStep,

        // XXX: create outside and pass in instead of passing zon in? maybe make a more generic step that just takes a exe to run, but, args?
        // XXX: also for now dup code wiht other step but, see if it stays around...
        fn create(owner: *std.Build, z: *std.Build.Module, t: std.zig.CrossTarget, o: std.builtin.Mode) Self {
            const exe = owner.addExecutable(.{
                .name = "bake-sprite",
                .root_source_file = .{ .path = "src/game/bake/bake_sprite_png.zig" },
                // XXX: ... re-getting because variables not available..
                .target = t,
                .optimize = o,
            });
            exe.addModule("zon", z);
            return .{
                .owner = owner,
                .exe = exe,
            };
        }

        // XXX: any way to make the anyopaque cast automatic? see articles about zig interfaces?
        fn run(ctx: *const anyopaque, args: BakeAssets.BakeStep.RunArgs) !?BakeAssets.BakeStep.BakedAsset {
            const self: *const Self = @ptrCast(@alignCast(ctx));
            // XXX: CURRENT: DOING: continue removing args not needed from the processor,
            // then we can move this to like a preprocess step that then feeds into a single sprite validation step or do a separate one of those later or dup it or whatever
            const baked_asset_path_out = try std.fmt.allocPrint(self.owner.allocator, "{s}.pimg.sprite.zon", .{args.asset_path_out});
            const process = self.owner.addRunArtifact(self.exe);
            process.addFileSourceArg(args.config_cached);
            const file_source = process.addOutputFileArg(baked_asset_path_out);
            return .{
                .file_source = file_source,
                .asset_path_out = baked_asset_path_out,
            };
        }

        pub fn bakeStep(self: *const @This()) BakeAssets.BakeStep {
            return .{
                .ptr = self,
                .vtable = &.{ .run = run },
            };
        }
    };
    const bake_sprite_png = BakeSpritePng.create(b, zon_module, target, optimize);
    var bake_sprites = BakeAssets.create(b);
    defer bake_sprites.deinit();
    try bake_sprites.addAssets(.{
        .path = data_path,
        .extension = ".sprite.png",
        .storage = .install,
        .bake_step = bake_sprite_png.bakeStep(),
    });
    // XXX: current: this!
    // - add a baker that verifies image sizes, and that we're not re-baking a .sprite.png
    // - to do this we need to read the .sprite.zig from the bake step, that's fine
    // - however, we need to be able to convert the ids in there to paths
    //   - we could pass in a /run step/ and give our own arguments before the baker does, for things like, the zon file defining
    //   the images. well it's a zig file right now but it should be a zon file eventually/can make intermediate or go straight to @import now.
    //   - we DON'T want to embed this zig file in the bake step, because then adding an image changes the bake steap leading to ALL images
    //   being rebaked right? then again, if it depends on it, that's true anyway..?
    //   - hmm this is tricky. if necessary we could do validation as a separate pass...but what if we actually wanted to combine files to make an asset for some reason?
    //     is that a use case we need to support? could accept that it reruns cause cheap but, what if not cheap?
    // can dedup later by moving files and reading from cached file locations..??
    // could also read the zon file from the build script and pass the args to the baker instead maybe?
    // ah yeah like you pass in a function that, given the zon and asset paths, decides which args to pass
    // alternatively we could make the bake step non atomic by using the file system? does that help at all?
    // okay yeah so i think we wanna let the args be decided from /here/
    // so..bake step would take a function that takes in the asset and zon paths, and then adds args to the compile step
    // wait it could evn just create run step?? right it can do as much work as it wants during build, and offload whatever it wants
    // to a build step! (may even be able to make this a function on the bake script ofr that asset type named something other
    // than main, if we want, idk)
    // XXX: NOTE: we have two seaprate sprite bake steps (shorthand for pngs), gotta do it on both, maybe prepreocess the others and add as input
    // to this step so there'sonly one?

    // XXX: then after that, we can make @import work on zon maybe??
    // XXX: need to auto create the json files if missing...also need to depend on them properly so changing them
    // triggers rebuilds when needed! and need to error on unused fields if the bake exe doesn't use them etc or require
    // it use them idk
    // XXX: too many extensions is annoying...just have one and require unique/add or modify to be .zig when needed?
    // XXX: for a more convenient shorthand, could allow nesting the sprite config in the image config,
    // instead of just making it the extension? only when applicable of course. ehhh we'd have to make a separate struct
    // so references to other images aren't allowed though right..? may just be more confusing.
    const BakeSprite = struct {
        const Self = @This();

        owner: *std.Build,
        exe: *std.Build.CompileStep,
        pew_exe: *std.Build.CompileStep,

        // XXX: error handling on all zon stuff...
        // XXX: temp dup definition
        const Tint = union(enum) {
            none,
            luminosity,
            mask: struct {
                // XXX: ...just inline once no other fields
                path: []const u8,
            },
        };

        const Sprite = struct {
            // XXX: naming etc
            diffuse_path: []const u8,
            degrees: f32 = 0.0,
            tint: Tint = .none,
        };

        fn create(
            owner: *std.Build,
            p: *std.Build.CompileStep,
            t: std.zig.CrossTarget,
            o: std.builtin.Mode,
        ) Self {
            const exe = owner.addExecutable(.{
                .name = "bake-sprite",
                .root_source_file = .{ .path = "src/game/bake/bake_sprite.zig" },
                .target = t,
                .optimize = o,
            });
            exe.addCSourceFile("src/game/bake/stb_image.c", &.{"-std=c99"});
            exe.addIncludePath("src/game/bake");
            exe.linkLibC();

            return .{
                .owner = owner,
                .exe = exe,
                .pew_exe = p,
            };
        }

        // XXX: also make it easy/automatic to validate ALL zon at bake time even when installed? do we need the
        // types anyway to be able to do install or no?
        fn run(ctx: *const anyopaque, args: BakeAssets.BakeStep.RunArgs) !?BakeAssets.BakeStep.BakedAsset {
            const self: *const Self = @ptrCast(@alignCast(ctx));

            const process = self.owner.addRunArtifact(self.exe);
            process.setName(try std.fmt.allocPrint(self.owner.allocator, "{s} ({s})", .{
                process.step.name,
                args.asset_path_in,
            }));

            // Read the sprite definition
            const sprite = b: {
                var zon_source = try self.owner.build_root.handle.readFileAllocOptions(
                    self.owner.allocator,
                    args.asset_path_in,
                    1024,
                    null,
                    @alignOf(u8),
                    0,
                );
                defer self.owner.allocator.free(zon_source);

                break :b try zon.parseFromSlice(Sprite, self.owner.allocator, zon_source, .{
                    // XXX: temp true...
                    .ignore_unknown_fields = true,
                });
            };
            defer zon.parseFree(self.owner.allocator, sprite);

            // Add an argument for the diffuse image
            {
                var diffuse_path = try std.fs.path.join(self.owner.allocator, &.{
                    std.fs.path.dirname(args.asset_path_in).?,
                    sprite.diffuse_path,
                });
                // defer self.owner.allocator.free(diffuse_path); // XXX: ...
                var diffuse_cached = args.bake_assets.cache_input.addCopyFile(
                    .{ .path = diffuse_path },
                    diffuse_path,
                );
                process.addFileSourceArg(diffuse_cached);
            }

            // Add an argument for the tint
            switch (sprite.tint) {
                .mask => |m| {
                    var mask_path = try std.fs.path.join(self.owner.allocator, &.{
                        std.fs.path.dirname(args.asset_path_in).?,
                        m.path,
                    });
                    // defer self.owner.allocator.free(mask_path); // XXX: ...
                    var mask_cached = args.bake_assets.cache_input.addCopyFile(
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
                var degrees = try std.fmt.allocPrint(self.owner.allocator, "{}", .{sprite.degrees});
                defer self.owner.allocator.free(degrees);
                process.addArg(degrees);
            }

            // Add an argument for the out path
            {
                const out_path = try std.fmt.allocPrint(
                    self.owner.allocator,
                    "{s}.tempimg", // XXX: pick extension once actually using
                    .{args.asset_path_out},
                );
                const file_source = process.addOutputFileArg(out_path);
                _ = file_source;
            }

            // XXX: can remove soon when we actually return the baked asset here...
            self.pew_exe.step.dependOn(&process.step);

            return null;
        }

        pub fn bakeStep(self: *const @This()) BakeAssets.BakeStep {
            return .{
                .ptr = self,
                .vtable = &.{ .run = run },
            };
        }
    };
    var bake_sprite = BakeSprite.create(b, pew_exe, target, optimize);
    try bake_sprites.addAssets(.{
        .path = data_path,
        .extension = ".sprite.zon",
        .storage = .install,
        .bake_step = bake_sprite.bakeStep(),
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
