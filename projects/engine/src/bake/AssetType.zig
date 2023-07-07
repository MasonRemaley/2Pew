const std = @import("std");
const zon = @import("zon").zon;
const FileSource = std.Build.FileSource;
const BakeStep = @import("BakeStep.zig");
const Baker = @import("Baker.zig");

const Self = @This();

const config_extension = "bake.zon";

bake_assets: *Baker,
assets: std.StringArrayHashMapUnmanaged(Asset),

// XXX: just make a path and an enum or no?
pub const Asset = union(enum) {
    install: []const u8,
    import: []const u8,
    embed: []const u8,
};

pub fn deinit(self: *Self) void {
    self.assets.deinit(self.bake_assets.owner.allocator);
    self.* = undefined;
}

pub const Storage = enum {
    install,
    import,
    embed,
};

pub const BatchOptions = struct {
    extension: []const u8,
    storage: Storage,
    bake_step: BakeStep = BakeStep.default,
    ignore_unknown_fields: bool = false,
};

const BakeConfig = struct {
    id: []const u8,
};

fn endsWithExtension(path: []const u8, extension: []const u8) bool {
    if (path.len < extension.len + 1) return false;
    if (path[path.len - extension.len - 1] != '.') return false;
    return std.mem.endsWith(u8, path, extension);
}

pub fn addBatch(self: *Self, options: BatchOptions) !void {
    const owner = self.bake_assets.owner;

    var assets_iterable = try owner.build_root.handle.openIterableDir(self.bake_assets.data_path, .{});
    defer assets_iterable.close();
    var walker = try assets_iterable.walk(owner.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            // Skip irrelevent files
            if (!endsWithExtension(entry.path, config_extension)) {
                continue;
            }
            if (!endsWithExtension(entry.path[0 .. entry.path.len - config_extension.len - 1], options.extension)) {
                continue;
            }

            // Calculate the paths relative to the build root
            const config_path = try std.fs.path.join(owner.allocator, &.{ self.bake_assets.data_path, entry.path });
            const data_path = config_path[0 .. config_path.len - config_extension.len - 1];
            const default_install_path = entry.path[0 .. entry.path.len - config_extension.len - 1];

            // Verify that the asset exists
            owner.build_root.handle.access(data_path, .{}) catch |err| {
                std.log.err("{s}: Failed to open corresponding asset ({s})", .{ config_path, data_path });
                return err;
            };

            // Bake the asset
            const baked = try add(options.bake_step, .{
                .data = data_path,
                .config = config_path,
                .install = default_install_path,
            });

            // Get the install path.
            const install_path = baked.install_path orelse owner.dupe(default_install_path);

            // Store the data
            switch (options.storage) {
                // XXX: implement!
                .import, .embed => unreachable,
                .install => {
                    const install = owner.addInstallFileWithDir(
                        baked.file_source,
                        .{ .custom = self.bake_assets.install_dir },
                        install_path,
                    );
                    self.bake_assets.write_output.step.dependOn(&install.step);
                },
            }

            // Parse the ID from the bake config
            // XXX: realloc from a fixed buffer allocaator each time?
            var zon_source = try entry.dir.readFileAllocOptions(
                owner.allocator,
                entry.basename,
                128,
                null,
                @alignOf(u8),
                0,
            );
            defer owner.allocator.free(zon_source);
            // XXX: eventually log good errors if zon files are invalid!
            // XXX: would be cool if strings that didn't need to be weren't reallocated, may already be the case internally?
            const config = try zon.parseFromSlice(BakeConfig, owner.allocator, zon_source, .{
                .ignore_unknown_fields = options.ignore_unknown_fields,
            });
            defer zon.parseFree(owner.allocator, config);

            // Write to the index
            const asset_entry = try self.assets.getOrPut(owner.allocator, owner.dupe(config.id));
            if (asset_entry.found_existing) {
                std.debug.print("error: duplicate asset id `{s}`\n", .{config.id});
                std.debug.print("  first occurence: `{s}`\n  second occurence: `{s}`\n", .{
                    install_path,
                    switch (asset_entry.value_ptr.*) {
                        inline else => |path| path,
                    },
                });
                return error.DuplicateAssetId;
            }
            asset_entry.value_ptr.* = switch (options.storage) {
                .install => .{ .install = install_path },
                .import => .{ .import = install_path },
                .embed => .{ .embed = install_path },
            };
        }
    }
}

fn add(bake_step: BakeStep, paths: BakeStep.Paths) !BakeStep.Baked {
    return bake_step.impl(bake_step.ctx, paths);
}

pub fn createModule(self: *const Self, filename: []const u8) !*std.Build.Module {
    const owner = self.bake_assets.owner;

    var index_bytes = std.ArrayListUnmanaged(u8){};
    var index_bytes_writer = index_bytes.writer(owner.allocator);
    try std.fmt.format(index_bytes_writer, "pub const descriptors = &.{{\n", .{});

    for (self.assets.entries.items(.key), self.assets.entries.items(.value)) |id, asset| {
        try std.fmt.format(index_bytes_writer, "    .{{\n", .{});
        // XXX: implementa zon writer so that an id having a quote won't break stuff
        try std.fmt.format(index_bytes_writer, "        .id = \"{s}\",\n", .{id});
        switch (asset) {
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
            .embed => unreachable,
            .install => |path| {
                // XXX: we always write forward slash, because we are going to cache this
                // file in some modes and need a way to normalize the output. On platforms
                // that *require* a backslash we can transition it on indexing or something.
                // Just make sure not to transition actual escapes...
                try index_bytes_writer.print("        .asset = .{{ .path = \"{}/{}\" }},\n", .{
                    fmtPath(self.bake_assets.install_prefix),
                    fmtPath(path),
                });
            },
        }
        try std.fmt.format(index_bytes_writer, "    }},\n", .{});
    }
    try std.fmt.format(index_bytes_writer, "}};", .{});

    // XXX: this could also be zon!
    return owner.createModule(.{
        .source_file = self.bake_assets.write_output.add(filename, index_bytes.items),
    });
}

/// Prints a path, replacing all '\\'s with '/' and escaping any special characters.
fn formatPath(
    bytes: []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    for (bytes) |byte| switch (byte) {
        '\\' => try writer.writeByte('/'),
        else => try writer.print("{" ++ fmt ++ "}", .{std.zig.fmtEscapes(&.{byte})}),
    };
}

pub fn fmtPath(bytes: []const u8) std.fmt.Formatter(formatPath) {
    return .{ .data = bytes };
}
