const std = @import("std");
const BakeAssets = @This();
const Step = std.Build.Step;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const BakeConfig = struct { id: []const u8 };

pub const StorageMode = enum {
    install,
    import,
    embed,
};

pub const AssetProcessor = struct {
    exe: *std.Build.CompileStep,
    output_extension: []const u8,
};

pub const Asset = struct {
    id: []const u8,
    data: union(enum) {
        install: []const u8,
        import: []const u8,
        embed: []const u8,
    },
};

owner: *std.Build,
cache_input: *Step.WriteFile,
write_output: *Step.WriteFile,
assets: ArrayListUnmanaged(Asset),

// XXX: require to specify whether it's a path or a import up front? or whatever that's called in game? or is
// this fine?
pub fn create(owner: *std.Build) BakeAssets {
    return .{
        .owner = owner,
        .cache_input = owner.addWriteFiles(),
        .write_output = owner.addWriteFiles(),
        .assets = ArrayListUnmanaged(Asset){},
    };
}

// XXX: naming of file vs of other stuff that will be here?
// XXX: allow asset groups for purposes of choosing random versions of things? e.g. an artist can
// add a file to a group via a config file or folder structure, and it shows up in game without the
// game needing to modify internal arrays of things. may also be useful for things like animations?
// XXX: asset packs for loading groups of assets together? (and verifying they exist?) if we make some of
// this dynamic instead of static we may want the missing asset fallbacks again?
// XXX: what about e.g. deleting an asset that wasn't yet released? we could have a way to mark them as such maye idk, on release
// it can change whether they need to be persistent
// XXX: make sure we can do e.g. zig build bake to just bake, add stdout so we can see what's happening even if clear after each line
// XXX: files seemingly never get DELETED from zig-out, is that expected..? seems like it could get us into
// trouble.
pub fn addAssets(
    self: *BakeAssets,
    data_path: []const u8,
    asset_extension: []const u8,
    storage: StorageMode,
    processor: ?AssetProcessor,
) !void {
    // XXX: look into how the build runner parses build.zon, maybe do that instead of json here! note that
    // we may eventually want to have extra fields that are only read during baking not when just getting the id.
    // though my thinking isn't clear on that part right now.
    // XXX: cache the index in source control as well in something readable (.zon or .json) and use
    // it as input when available to verify that assets weren't missing and such?
    // XXX: catch duplicate ids and such here?
    const config_extension = ".json";
    var data_path_absolute = try self.owner.build_root.join(self.owner.allocator, &.{data_path});
    defer self.owner.allocator.free(data_path_absolute);
    var assets_iterable = try std.fs.openIterableDirAbsolute(data_path_absolute, .{});
    defer assets_iterable.close();
    var walker = try assets_iterable.walk(self.owner.allocator);
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

            // Determine the file paths
            var config_path_in = try std.fs.path.join(self.owner.allocator, &.{ data_path, entry.path });
            // defer self.owner.allocator.free(config_path_in); // XXX: ...
            const asset_path_in = config_path_in[0 .. config_path_in.len - config_extension.len];
            var asset_path_out = try std.fs.path.join(self.owner.allocator, &.{ "data", entry.path[0 .. entry.path.len - config_extension.len] });
            // XXX: ... defer self.owner.allocator.free(asset_path_out); also gonna overwrite..weird pattern, make new var?
            std.mem.replaceScalar(u8, asset_path_out, '\\', '/');

            // XXX: make sure only stuff that needs to is getting rebuilt...
            var config_cached = self.cache_input.addCopyFile(.{ .path = config_path_in }, config_path_in);
            var asset_cached = self.cache_input.addCopyFile(.{ .path = asset_path_in }, asset_path_in);

            // Process the asset
            var processed_asset = if (processor) |p| b: {
                asset_path_out = try std.fmt.allocPrint(self.owner.allocator, "{s}{s}", .{ asset_path_out[0 .. asset_path_out.len - asset_extension.len], p.output_extension });
                const process = self.owner.addRunArtifact(p.exe);
                process.addFileSourceArg(asset_cached);
                process.addFileSourceArg(config_cached);
                break :b process.addOutputFileArg(asset_path_out);
            } else asset_cached;

            // Store the data
            switch (storage) {
                .import, .embed => _ = self.write_output.addCopyFile(processed_asset, asset_path_out),
                .install => {
                    const install = self.owner.addInstallFile(processed_asset, asset_path_out);
                    self.write_output.step.dependOn(&install.step);
                },
            }

            // Parse the ID from the bake config
            var file = try assets_iterable.dir.openFile(entry.path, .{});
            defer file.close();
            var json_reader = std.json.reader(self.owner.allocator, file.reader());
            defer json_reader.deinit();
            // XXX: make sure it's obvious what file caused the problem if this parse fails! use the new
            // line number API too?
            var config = try std.json.parseFromTokenSource(BakeConfig, self.owner.allocator, &json_reader, .{
                // XXX: have this be an option or keep it automatic?
                .ignore_unknown_fields = processor != null,
            });
            // XXX: don't free if we're passing the id out...though could free when we free this maybe
            // defer std.json.parseFree(BakeConfig, self.owner.allocator, config);

            // Write to the index
            try self.assets.append(self.owner.allocator, .{
                // XXX: leaking to avoid freeing too early...
                .id = try self.owner.allocator.dupe(u8, config.value.id),
                .data = switch (storage) {
                    .install => .{ .install = asset_path_out },
                    .import => .{ .import = asset_path_out },
                    .embed => .{ .embed = asset_path_out },
                },
            });
        }
    }
}

pub fn deinit(self: *BakeAssets) void {
    self.assets.deinit(self.owner.allocator);
    self.* = undefined;
}

pub fn createModule(self: *const BakeAssets) !*std.Build.Module {
    var index_bytes = ArrayListUnmanaged(u8){};
    var index_bytes_writer = index_bytes.writer(self.owner.allocator);
    try std.fmt.format(index_bytes_writer, "pub const descriptors = &.{{\n", .{});

    for (self.assets.items) |asset| {
        try std.fmt.format(index_bytes_writer, "    .{{\n", .{});
        // XXX: what if the id/such has a quote in it..??
        try std.fmt.format(index_bytes_writer, "        .id = \"{s}\",\n", .{asset.id});
        switch (asset.data) {
            .import => |path| {
                try std.fmt.format(index_bytes_writer, "        .asset = @import(\"{s}\").asset,\n", .{path});
            },
            .embed => |path| {
                try std.fmt.format(index_bytes_writer, "        .asset = .{{ .data = @embedFile(\"{s}\") }},\n", .{path});
            },
            .install => |path| {
                try std.fmt.format(index_bytes_writer, "        .asset = .{{ .path = \"{s}\" }},\n", .{path});
            },
        }
        try std.fmt.format(index_bytes_writer, "    }},\n", .{});
    }
    try std.fmt.format(index_bytes_writer, "}};", .{});

    return self.owner.createModule(.{
        .source_file = self.write_output.add("index.zig", index_bytes.items),
    });
}
