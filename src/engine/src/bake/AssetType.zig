const std = @import("std");
const zon = @import("zon").zon;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const BakeStep = @import("BakeStep.zig");
const Baker = @import("Baker.zig");

const Self = @This();

bake_assets: *Baker,
assets: ArrayListUnmanaged(Asset),

pub const Asset = struct {
    id: []const u8,
    data: union(enum) {
        install: []const u8,
        import: []const u8,
        embed: []const u8,
    },
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

pub fn addBatch(self: *Self, options: BatchOptions) !void {
    const config_extension = ".bake.zon";

    var assets_iterable = try self.bake_assets.owner.build_root.handle.openIterableDir(self.bake_assets.data_path, .{});
    defer assets_iterable.close();
    var walker = try assets_iterable.walk(self.bake_assets.owner.allocator);
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

            // Calculate the paths relative to the build root
            const config_path = try std.fs.path.join(self.bake_assets.owner.allocator, &.{ self.bake_assets.data_path, entry.path });
            const data_path = config_path[0 .. config_path.len - config_extension.len];
            const default_install_path = entry.path[0 .. entry.path.len - config_extension.len];

            // Verify that the asset exists
            self.bake_assets.owner.build_root.handle.access(data_path, .{}) catch |err| {
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
            const install_path = baked.install_path orelse self.bake_assets.owner.dupe(default_install_path);

            // Store the data
            switch (options.storage) {
                // XXX: implement!
                .import, .embed => unreachable,
                .install => {
                    const install = self.bake_assets.owner.addInstallFileWithDir(
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
                self.bake_assets.owner.allocator,
                entry.basename,
                128,
                null,
                @alignOf(u8),
                0,
            );
            defer self.bake_assets.owner.allocator.free(zon_source);
            // XXX: eventually log good errors if zon files are invalid!
            // XXX: would be cool if strings that didn't need to be weren't reallocated, may already be the case internally?
            const config = try zon.parseFromSlice(BakeConfig, self.bake_assets.owner.allocator, zon_source, .{
                .ignore_unknown_fields = options.ignore_unknown_fields,
            });
            defer zon.parseFree(self.bake_assets.owner.allocator, config);

            // Write to the index
            try self.assets.append(self.bake_assets.owner.allocator, .{
                .id = self.bake_assets.owner.dupe(config.id),
                .data = switch (options.storage) {
                    .install => .{ .install = install_path },
                    .import => .{ .import = install_path },
                    .embed => .{ .embed = install_path },
                },
            });
        }
    }
}

fn add(bake_step: BakeStep, paths: BakeStep.Paths) !BakeStep.Baked {
    return bake_step.impl(bake_step.ctx, paths);
}

// XXX: why do I need unique filenames now when I didn't before?
pub fn createModule(self: *const Self, filename: []const u8) !*std.Build.Module {
    var index_bytes = ArrayListUnmanaged(u8){};
    var index_bytes_writer = index_bytes.writer(self.bake_assets.owner.allocator);
    try std.fmt.format(index_bytes_writer, "pub const descriptors = &.{{\n", .{});

    for (self.assets.items) |asset| {
        try std.fmt.format(index_bytes_writer, "    .{{\n", .{});
        // XXX: implementa zon writer so that an id having a quote won't break stuff
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
            .embed => unreachable,
            .install => |path| {
                // XXX: instead add a way to escape strings when writing zon?
                // XXX: hmm data hard coded here...that's actually fine if we hard code it elsewhere too, can always make
                // configurabel if we want. but we want a path relative to the root basically.
                try std.fmt.format(index_bytes_writer, "        .asset = .{{ .path = \"", .{});
                try writePath(index_bytes_writer, self.bake_assets.install_prefix);
                try writeSep(index_bytes_writer);
                try writePath(index_bytes_writer, path);
                try std.fmt.format(index_bytes_writer, "\" }},\n", .{});
            },
        }
        try std.fmt.format(index_bytes_writer, "    }},\n", .{});
    }
    try std.fmt.format(index_bytes_writer, "}};", .{});

    // XXX: this could also be zon!
    return self.bake_assets.owner.createModule(.{
        .source_file = self.bake_assets.write_output.add(filename, index_bytes.items),
    });
}

fn writeSep(writer: anytype) !void {
    if (std.fs.path.sep == '\\') {
        try std.fmt.format(writer, "\\\\", .{});
    } else {
        try writer.writeByte(std.fs.path.sep);
    }
}

fn writePath(writer: anytype, path: []const u8) !void {
    for (path) |c| {
        if (c == '\\' or c == '/') {
            try writeSep(writer);
        } else {
            try writer.writeByte(c);
        }
    }
}
