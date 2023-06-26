const std = @import("std");
const zon = @import("zon").zon;
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

pub const AddAssetsOptions = struct {
    path: []const u8,
    extension: []const u8,
    storage: StorageMode,
    // XXX: rename ot bake step? but whole thing is bake step?
    processor: ?AssetProcessor = null,
    ignore_unknown_fields: bool = false,
};

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
pub fn addAssets(self: *BakeAssets, options: AddAssetsOptions) !void {
    // XXX: look into how the build runner parses build.zon, maybe do that instead of json here! note that
    // we may eventually want to have extra fields that are only read during baking not when just getting the id.
    // though my thinking isn't clear on that part right now.
    // XXX: cache the index in source control as well in something readable (.zon or .json) and use
    // it as input when available to verify that assets weren't missing and such?
    // XXX: catch duplicate ids and such here?
    const config_extension = ".bake.zon";
    var path_absolute = try self.owner.build_root.join(self.owner.allocator, &.{options.path});
    defer self.owner.allocator.free(path_absolute);
    var assets_iterable = try std.fs.openIterableDirAbsolute(path_absolute, .{});
    defer assets_iterable.close();
    var walker = try assets_iterable.walk(self.owner.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            // Skip irrelevent files
            if (!std.mem.endsWith(u8, entry.path, config_extension)) {
                continue;
            }
            if (!std.mem.endsWith(u8, entry.path[0 .. entry.path.len - config_extension.len], options.extension)) {
                continue;
            }

            // Determine the file paths
            var config_path_in = try std.fs.path.join(self.owner.allocator, &.{ options.path, entry.path });
            // defer self.owner.allocator.free(config_path_in); // XXX: ...
            const asset_path_in = config_path_in[0 .. config_path_in.len - config_extension.len];
            var asset_path_out = try std.fs.path.join(self.owner.allocator, &.{ "data", entry.path[0 .. entry.path.len - config_extension.len] });
            // XXX: ... defer self.owner.allocator.free(asset_path_out); also gonna overwrite..weird pattern, make new var?
            std.mem.replaceScalar(u8, asset_path_out, '\\', '/');

            // XXX: make sure only stuff that needs to is getting rebuilt...
            var config_cached = self.cache_input.addCopyFile(.{ .path = config_path_in }, config_path_in);
            var asset_cached = self.cache_input.addCopyFile(.{ .path = asset_path_in }, asset_path_in);

            // Process the asset
            var processed_asset = if (options.processor) |p| b: {
                asset_path_out = try std.fmt.allocPrint(self.owner.allocator, "{s}{s}", .{ asset_path_out[0 .. asset_path_out.len - options.extension.len], p.output_extension });
                const process = self.owner.addRunArtifact(p.exe);
                process.addFileSourceArg(asset_cached);
                process.addFileSourceArg(config_cached);
                break :b process.addOutputFileArg(asset_path_out);
            } else asset_cached;

            // Store the data
            switch (options.storage) {
                .import, .embed => _ = self.write_output.addCopyFile(processed_asset, asset_path_out),
                .install => {
                    const install = self.owner.addInstallFile(processed_asset, asset_path_out);
                    self.write_output.step.dependOn(&install.step);
                },
            }

            // Parse the ID from the bake config
            // XXX: realloc from a fixed buffer allocaator each time?
            var zon_source = try assets_iterable.dir.readFileAllocOptions(
                self.owner.allocator,
                entry.path,
                128,
                null,
                @alignOf(u8),
                0,
            );
            defer self.owner.allocator.free(zon_source);
            // XXX: eventually log good errors if zon files are invalid!
            const config = try zon.parseFromSlice(BakeConfig, self.owner.allocator, zon_source, .{
                .ignore_unknown_fields = options.ignore_unknown_fields,
            });
            // XXX: would be cool if strings that didn't need to be werent' reallocated, may already be the case internally?
            defer zon.parseFree(self.owner.allocator, config);

            // Write to the index
            try self.assets.append(self.owner.allocator, .{
                // XXX: don't free if we're passing the id out...though could free when we free this maybe
                .id = try self.owner.allocator.dupe(u8, config.id),
                .data = switch (options.storage) {
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
                _ = path;
                // XXX: can use @import again once we add support for that for zon!!
                // XXX: also can allow installing these since zon can be loaded at runtime too! and then this step
                // just gets combined with embed, it just embeds zon rather than the string?
                // try std.fmt.format(index_bytes_writer, "        .asset = @import(\"{s}\").asset,\n", .{path});
                // XXX: actually embedding the source is annoying, because we don't yet know the path, so lets
                // implement install for this in the meantime and only implement import once we CAN do @import here.
                unreachable;
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

    // XXX: this could also be zon!
    return self.owner.createModule(.{
        .source_file = self.write_output.add("index.zig", index_bytes.items),
    });
}