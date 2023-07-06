// XXX:
// - need to do
//    - build system is supposed to be duping strings for me apparently?
//    - force verificaiton of all zon at bake time?
//    - get embedding working again (need to be able to import zon first)
//    - auto create the id files, rename to id, possibly just have id in them?
//    - report good errors on zon stuff (test error handling api in practice!)
//    - what about e.g. deleting an asset that wasn't yet released? we could have a way to mark them as such maye idk, on release
//      it can change whether they need to be persistent
//   - cache the index in source control as well in something readable (.zon or .json) and use
//     it as input when available to verify that assets weren't missing and such?
// - ideas
//    - allow asset groups for purposes of choosing random versions of things? e.g. an artist can
//      add a file to a group via a config file or folder structure, and it shows up in game without the
//      game needing to modify internal arrays of things. may also be useful for things like animations?
//    - asset packs for loading groups of assets together? (and verifying they exist?) if we make some of
//      this dynamic instead of static we may want the missing asset fallbacks again?

// XXX: all still needed?
const std = @import("std");
const pew = @import("projects/game/build-helper.zig");

pub fn build(b: *std.Build) !void {
    // Standard options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Custom options
    const use_llvm = b.option(bool, "use-llvm", "use zig's llvm backend");

    // Steps
    const test_step = b.step("test", "Run unit tests");
    const bench_step = b.step("bench", "Run benchmarks");

    // Build packages
    //
    // We only have a single true build script so that there is a single shared cache. We only build
    // the requested game to avoid calculating build graphs for assets for games not being built.
    const Game = enum { pew };
    const game = Game.pew;
    switch (game) {
        .pew => try pew.build(b, .{
            .target = target,
            .optimize = optimize,
            .test_step = test_step,
            .bench_step = bench_step,
            .use_llvm = use_llvm,
        }),
    }
}
