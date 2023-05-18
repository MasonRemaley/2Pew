const std = @import("std");
const BakeAssets = @This();
const Step = std.Build.Step;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const BakeConfig = struct { id: []const u8 };

// XXX: CURRENT: Okay, next up is allowing for custom build steps to be inserted into here to do actual
// baking. They'll take the current file as input, and provide an output path with a configured extension
// and then feed that to the rest of this as before.
// XXX: custom: *std.Build.CompileStep,
// XXX: instead of writing index directly, accumulate in array that can be used for further
// processing or combined with bake steps for files from other locations or baked in other ways
// etc.
pub const Baker = union(enum) {
    install: void,
    import: void,
    embed: void,
};

step: *Step,
// XXX: naming index vs asset_descriptors?
index: std.Build.FileSource,

// XXX: naming of file vs of other stuff that will be here?
// XXX: organize other code into modules? separate build scripts..??
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
pub fn create(owner: *std.Build, data_path: []const u8, asset_extension: []const u8, baker: Baker) !BakeAssets {
    var copy_assets = owner.addWriteFiles();

    var index_bytes = ArrayListUnmanaged(u8){};
    defer index_bytes.deinit(owner.allocator);
    var index_bytes_writer = index_bytes.writer(owner.allocator);
    try std.fmt.format(index_bytes_writer, "pub const descriptors = &.{{\n", .{});

    // XXX: generate missing json files
    // XXX: look into how the build runner parses build.zon, maybe do that instead of json here! note that
    // we may eventually want to have extra fields that are only read during baking not when just getting the id.
    // though my thinking isn't clear on that part right now.
    // XXX: cache the index in source control as well in something readable (.zon or .json) and use
    // it as input when available to verify that assets weren't missing and such?
    // XXX: catch duplicate ids and such here?
    const config_extension = ".json";
    var data_path_absolute = try owner.build_root.join(owner.allocator, &.{data_path});
    defer owner.allocator.free(data_path_absolute);
    var assets_iterable = try std.fs.openIterableDirAbsolute(data_path_absolute, .{});
    defer assets_iterable.close();
    var walker = try assets_iterable.walk(owner.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            // Skip irrelevent files
            if (!std.mem.endsWith(u8, entry.path, config_extension)) {
                continue;
            }
            if (!std.mem.endsWith(u8, entry.path[0 .. entry.path.len - config_extension.len], asset_extension)) {
                continue;
            }

            // XXX: can't free these strings right..?
            // Determine the file paths
            var config_path_in = try std.fs.path.join(owner.allocator, &.{ data_path, entry.path });
            // defer owner.allocator.free(config_path_in);
            const asset_path_in = config_path_in[0 .. config_path_in.len - config_extension.len];
            var asset_path_out = try std.fs.path.join(owner.allocator, &.{ "data", entry.path[0 .. entry.path.len - config_extension.len] });
            // defer owner.allocator.free(asset_path_out);
            std.mem.replaceScalar(u8, asset_path_out, '\\', '/');

            // Perform the bake
            switch (baker) {
                .import, .embed => _ = copy_assets.addCopyFile(.{ .path = asset_path_in }, asset_path_out),
                .install => owner.installFile(asset_path_in, asset_path_out),
            }

            // Parse the ID from the bake config
            var file = try assets_iterable.dir.openFile(entry.path, .{});
            defer file.close();
            var source = try file.readToEndAlloc(owner.allocator, 1000000);
            defer owner.allocator.free(source);
            var config = try std.json.parseFromSlice(BakeConfig, owner.allocator, source, .{});
            defer config.deinit();

            // Write to the index
            try std.fmt.format(index_bytes_writer, "    .{{\n", .{});
            try std.fmt.format(index_bytes_writer, "        .id = \"{s}\",\n", .{config.value.id});
            switch (baker) {
                .import => {
                    try std.fmt.format(index_bytes_writer, "        .asset = @import(\"{s}\").asset,\n", .{asset_path_out});
                },
                .embed => {
                    try std.fmt.format(index_bytes_writer, "        .asset = .{{ .data = @embedFile(\"{s}\") }},\n", .{asset_path_out});
                },
                .install => {
                    try std.fmt.format(index_bytes_writer, "        .asset = .{{ .path = \"{s}\" }},\n", .{asset_path_out});
                },
            }
            try std.fmt.format(index_bytes_writer, "    }},\n", .{});
        }
    }
    try std.fmt.format(index_bytes_writer, "}};\n", .{});

    // Store the index
    const index = copy_assets.add("index.zig", index_bytes.items);

    return .{
        .step = &copy_assets.step,
        .index = index,
    };
}

// const std = @import("std");
// // XXX: these deps okay..?
// // const asset_index = @import("asset_index.zig");
// // const asset_indexer = @import("asset_indexer.zig");
// // const Animation = asset_index.Animation;
// // const Descriptor = asset_indexer.Descriptor;

// const BakeConfig = struct { id: []const u8 };

// // XXX: move to main src, figure out how to isolate, maybe move some of the build logic into a function in here
// // XXX: never free memory here it's a short lived process, just use a fixed buffer allocator from some pages or something
// // XXX: this reader is buffered right?
// pub fn main() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();

//     const args = try std.process.argsAlloc(allocator);
//     defer std.process.argsFree(allocator, args);

//     if (args.len != 4) {
//         std.debug.panic("expected three arguments", .{});
//     }

//     const json_path = args[1];
//     const zig_path = args[2];
//     const out_path = args[3];

//     var file = try std.fs.openFileAbsolute(json_path, .{});
//     defer file.close();
//     var source = try file.readToEndAlloc(allocator, 1000000);
//     var tokens = std.json.TokenStream.init(source);
//     const parse_options = .{ .allocator = allocator };
//     var config = try std.json.parse(BakeConfig, &tokens, parse_options);
//     defer std.json.parseFree(BakeConfig, config, parse_options);

//     // XXX: rename to persistent_id so it's clear you shouldn't change it?
//     std.debug.print("bake id {s}\n", .{config.id});
//     std.debug.print("zig {s}\n", .{zig_path});
//     std.debug.print("output! {s}\n", .{out_path});

//     // XXX: options?
//     try std.fs.copyFileAbsolute(zig_path, out_path, .{});
// }
