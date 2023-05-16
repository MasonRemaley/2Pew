const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

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
    // once we create the bake step
    b.installDirectory(.{
        .source_dir = "data",
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

    // XXX: pull this code out into its own step or something that we can put in library code
    // XXX: organize other code into modules?
    // XXX: eventually do baking of things like tints here
    // XXX: allow asset groups for purposes of choosing random versions of things? e.g. an artist can
    // add a file to a group via a config file or folder structure, and it shows up in game without the
    // game needing to modify internal arrays of things. may also be useful for things like animations?
    // XXX: asset packs for loading groups of assets together? (and verifying they exist?) if we make some of
    // this dynamic instead of static we may want the missing asset fallbacks again?
    // XXX: allow speicfying the same input asset with different bake settings multiple times?
    // XXX: what about e.g. deleting an asset that wasn't yet released? we could have a way to mark them as such maye idk, on release
    // it can change whether they need to be persistent
    // XXX: may eventually do something like foo.anim.zig and foo.bake.json? or just use those extensions? but can be
    // dups if same name different types still for bake file so like foo.anim and foo.anim.bake I think is most readable! but
    // is annoying that doesn't say json/zig for easier syntax highlighting, that'd be foo.anim.zig and foo.anim.bake.json
    // can just config editors that way it's not a big deal...and will visually recognize/work with the formats etc don't need to specify.
    // XXX: make sure we can do e.g. zig build bake to just bake, add stdout so we can see what's happening even if clear after each line
    {
        var copy_assets = b.addWriteFiles();
        var index_bytes = ArrayListUnmanaged(u8){};
        defer index_bytes.deinit(b.allocator);

        try index_bytes.appendSlice(b.allocator, "pub const descriptors = &.{\n");

        const BakeConfig = struct { id: []const u8 };

        // XXX: look into how the build runner parses build.zon, maybe do that instead of json here!
        // XXX: cache the index in source control as well in something readable (.zon or .json) and use
        // it as input when available to verify that assets weren't missing and such?
        const extension = ".json";
        const data_path = "data";
        // XXX: don't use cwd here, is place build was run from!
        var animations_iterable = try std.fs.cwd().makeOpenPathIterable(data_path, .{});
        defer animations_iterable.close();
        var walker = try animations_iterable.walk(b.allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                if (std.mem.endsWith(u8, entry.path, extension)) {
                    var asset_path = try std.fmt.allocPrint(b.allocator, "{s}.zig", .{entry.path[0 .. entry.path.len - extension.len]});
                    std.mem.replaceScalar(u8, asset_path, '\\', '/');
                    var zig_in_path = try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ data_path, asset_path });
                    var zig_out_path = try std.fmt.allocPrint(b.allocator, "data/{s}", .{asset_path});

                    _ = copy_assets.addCopyFile(.{ .path = zig_in_path }, zig_out_path);

                    var file = try animations_iterable.dir.openFile(entry.path, .{});
                    defer file.close();
                    var source = try file.readToEndAlloc(b.allocator, 1000000);
                    defer b.allocator.free(source);
                    var config = try std.json.parseFromSlice(BakeConfig, b.allocator, source, .{});
                    defer config.deinit();

                    // XXX: can look into how build.zig.zon is loaded?
                    try index_bytes.appendSlice(b.allocator,
                        \\    .{
                        \\        .id = "
                    );
                    try index_bytes.appendSlice(b.allocator, config.value.id);
                    try index_bytes.appendSlice(b.allocator,
                        \\",
                        \\        .asset = @import("data/
                    );
                    try index_bytes.appendSlice(b.allocator, asset_path);
                    try index_bytes.appendSlice(b.allocator,
                        \\").asset,
                        \\    },
                        \\
                    );
                }
            }
        }
        try index_bytes.appendSlice(b.allocator, "};\n");

        const index_file = copy_assets.add("index.zig", index_bytes.items);

        exe.step.dependOn(&copy_assets.step);
        exe.addModule("asset_descriptors", b.createModule(.{
            .source_file = index_file,
        }));
    }

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
