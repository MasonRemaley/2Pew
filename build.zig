// XXX: baking todo
// - don't have paths like src/game/data hard coded into the build helper so things can be moved more easily?
// - generate ids automatically?
// - make sure generated files can't overwrite eachother!
// - don't set up the graph for the game's asset build unless actually building the game--eventually this
// will be actual work!
// - build system is supposed to be duping strings for me apparently?
// - use step.fail for failures? step.adderror?
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
// - make sure only stuff that needs to is getting rebuilt...
// - allow asset groups for purposes of choosing random versions of things? e.g. an artist can
// add a file to a group via a config file or folder structure, and it shows up in game without the
// game needing to modify internal arrays of things. may also be useful for things like animations?
// - asset packs for loading groups of assets together? (and verifying they exist?) if we make some of
// this dynamic instead of static we may want the missing asset fallbacks again?
// - what about e.g. deleting an asset that wasn't yet released? we could have a way to mark them as such maye idk, on release
// it can change whether they need to be persistent
// - make sure we can do e.g. zig build bake to just bake, add stdout so we can see what's happening even if clear after each line
// - files seemingly never get DELETED from zig-out, is that expected..? seems like it could get us into
// trouble.
// - cache the index in source control as well in something readable (.zon or .json) and use
// it as input when available to verify that assets weren't missing and such?
// - catch duplicate ids and such here?

// XXX: all still needed?
const std = @import("std");
const zon = @import("zon").zon;
const pew = @import("src/game/build-helper.zig");

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
    try pew.build(b, .{
        .target = target,
        .optimize = optimize,
        .test_step = test_step,
        .bench_step = bench_step,
        .use_llvm = use_llvm,
    });
}
