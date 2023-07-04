const std = @import("std");
const zon = @import("zon").zon;
const BakeAssets = @This();
const Step = std.Build.Step;
const FileSource = std.Build.FileSource;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const BakeConfig = struct { id: []const u8 };

pub const StorageMode = enum {
    install,
    import,
    embed,
};

// XXX: rename to step?
pub const BakeStep = struct {
    const Self = @This();

    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        add: *const fn (ctx: *const anyopaque, asset: Paths) anyerror!Baked,
    };

    /// It is safe to assume the strings will not be freed prior to build graph execution.
    pub const Paths = struct {
        /// The path to the asset. Will not be freed before build graph execution.
        data: []const u8,
        /// The path to the bake config. Will not be freed before build graph execution.
        config: []const u8,
        /// The default install path for this asset.
        install: []const u8,
    };

    pub const Baked = struct {
        // The baked file.
        file_source: FileSource,
        // The path at which to install the asset. If null uses the default.
        install_path: ?[]const u8 = null,
    };

    /// Adds a run artifact, gives it an input arg, and names the process `$NAME (input_path)`.
    pub fn addRunArtifactWithInput(exe: *Step.Compile, input_path: []const u8) !*Step.Run {
        const process = exe.step.owner.addRunArtifact(exe);
        const name = try std.fmt.allocPrint(exe.step.owner.allocator, "{s} ({s})", .{
            process.step.name,
            input_path,
        });
        process.setName(name);

        const write_step = exe.step.owner.addWriteFiles();
        const file_source = write_step.addCopyFile(FileSource.relative(input_path), input_path);
        process.addFileSourceArg(file_source);

        return process;
    }

    fn add(self: *const Self, paths: Paths) !Baked {
        return self.vtable.add(self.ptr, paths);
    }

    fn addCopy(_: *const anyopaque, paths: Paths) !Baked {
        return .{
            .file_source = FileSource.relative(paths.data),
        };
    }

    const default = Self{
        .ptr = undefined,
        .vtable = &.{ .add = addCopy },
    };
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
write_output: *Step.WriteFile,
assets: ArrayListUnmanaged(Asset),

pub fn create(owner: *std.Build) BakeAssets {
    return .{
        .owner = owner,
        .write_output = owner.addWriteFiles(),
        .assets = ArrayListUnmanaged(Asset){},
    };
}

pub const AddAssetsOptions = struct {
    path: []const u8,
    extension: []const u8,
    storage: StorageMode,
    bake_step: BakeStep = BakeStep.default,
    ignore_unknown_fields: bool = false,
};

pub fn addAssets(self: *BakeAssets, options: AddAssetsOptions) !void {
    const config_extension = ".bake.zon";

    var assets_iterable = try self.owner.build_root.handle.openIterableDir(options.path, .{});
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

            // Calculate the paths relative to the build root
            const config_path = try std.fs.path.join(self.owner.allocator, &.{ options.path, entry.path });
            const data_path = config_path[0 .. config_path.len - config_extension.len];
            const default_install_path = entry.path[0 .. entry.path.len - config_extension.len];

            // Verify that the asset exists
            self.owner.build_root.handle.access(data_path, .{}) catch |err| {
                std.log.err("{s}: Failed to open corresponding asset ({s})", .{ config_path, data_path });
                return err;
            };

            // Bake the asset
            const baked = try options.bake_step.add(.{
                .data = data_path,
                .config = config_path,
                .install = default_install_path,
            });

            // Get the install path.
            const install_path = baked.install_path orelse self.owner.dupe(default_install_path);

            // Store the data
            switch (options.storage) {
                // XXX: implement!
                .import, .embed => unreachable,
                .install => {
                    const install = self.owner.addInstallFileWithDir(
                        baked.file_source,
                        .{ .custom = "data" },
                        install_path,
                    );
                    self.write_output.step.dependOn(&install.step);
                },
            }

            // Parse the ID from the bake config
            // XXX: realloc from a fixed buffer allocaator each time?
            var zon_source = try entry.dir.readFileAllocOptions(
                self.owner.allocator,
                entry.basename,
                128,
                null,
                @alignOf(u8),
                0,
            );
            defer self.owner.allocator.free(zon_source);
            // XXX: eventually log good errors if zon files are invalid!
            // XXX: would be cool if strings that didn't need to be weren't reallocated, may already be the case internally?
            const config = try zon.parseFromSlice(BakeConfig, self.owner.allocator, zon_source, .{
                .ignore_unknown_fields = options.ignore_unknown_fields,
            });
            defer zon.parseFree(self.owner.allocator, config);

            // Write to the index
            try self.assets.append(self.owner.allocator, .{
                .id = self.owner.dupe(config.id),
                .data = switch (options.storage) {
                    .install => .{ .install = install_path },
                    .import => .{ .import = install_path },
                    .embed => .{ .embed = install_path },
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
                try std.fmt.format(index_bytes_writer, "        .asset = .{{ .path = \"data/", .{});
                for (path) |c| {
                    if (c == '\\') {
                        try index_bytes_writer.writeByte('/');
                    } else {
                        try index_bytes_writer.writeByte(c);
                    }
                }
                try std.fmt.format(index_bytes_writer, "\" }},\n", .{});
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
