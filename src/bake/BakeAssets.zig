const std = @import("std");
const BakeAssets = @This();
const Step = std.Build.Step;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const BakeConfig = struct { id: []const u8 };

// XXX: instead of writing index directly, accumulate in array that can be used for further
// processing or combined with bake steps for files from other locations or baked in other ways
// etc.
pub const StorageMode = union(enum) {
    install: void,
    import: void,
    embed: void,
};

pub const AssetProcessor = struct {
    exe: *std.Build.CompileStep,
    output_extension: []const u8,
};

step: *Step,
// XXX: naming index vs asset_descriptors?
index: std.Build.FileSource,

// XXX: naming of file vs of other stuff that will be here?
// XXX: organize other code into modules? separate build scripts..??
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
// XXX: okay so to bake the different colors..I guess we'll make multiple json files?? or we can make it an array that
// processes the same input multiple times? it's a bit confusing...think it through.
// XXX: files seemingly never get DELETED from zig-out, is that expected..? seems like it could get us into
// trouble.
pub fn create(
    owner: *std.Build,
    data_path: []const u8,
    asset_extension: []const u8,
    processor: ?AssetProcessor,
    storage: StorageMode,
) !BakeAssets {
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
            // XXX: ... defer owner.allocator.free(asset_path_out); also gonna overwrite..weird pattern, make new var?
            std.mem.replaceScalar(u8, asset_path_out, '\\', '/');

            // Process the asset
            var processed_asset = if (processor) |p| b: {
                asset_path_out = try std.fmt.allocPrint(owner.allocator, "{s}{s}", .{ asset_path_out[0 .. asset_path_out.len - asset_extension.len], p.output_extension });
                const process = owner.addRunArtifact(p.exe);
                process.addArg(asset_path_in);
                break :b process.addOutputFileArg(asset_path_out);
            } else std.Build.FileSource{ .path = asset_path_in };

            // Store the data
            switch (storage) {
                .import, .embed => _ = copy_assets.addCopyFile(processed_asset, asset_path_out),
                .install => {
                    var install = owner.addInstallFile(processed_asset, asset_path_out);
                    // XXX: does this make sense? we just need something to depend on it so it gets
                    // done...
                    copy_assets.step.dependOn(&install.step);
                },
            }

            // Parse the ID from the bake config
            var file = try assets_iterable.dir.openFile(entry.path, .{});
            defer file.close();
            var json_reader = std.json.reader(owner.allocator, file.reader());
            defer json_reader.deinit();
            // XXX: make sure it's obvious what file caused the problem if this parse fails! use the new
            // line number API too?
            var config = try std.json.parseFromTokenSource(BakeConfig, owner.allocator, &json_reader, .{
                // XXX: have this be an option or keep it automatic?
                .ignore_unknown_fields = processor != null,
            });
            defer config.deinit();

            // Write to the index
            try std.fmt.format(index_bytes_writer, "    .{{\n", .{});
            try std.fmt.format(index_bytes_writer, "        .id = \"{s}\",\n", .{config.value.id});
            switch (storage) {
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
