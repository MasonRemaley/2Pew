const std = @import("std");

// XXX: https://github.com/ziglang/zig/issues/1945
pub const AssetSource = union(enum) {
    // XXX: naming of these..?
    value: type,
    file: void,

    fn instanceType(comptime self: @This()) type {
        return switch (self) {
            .value => |ty| ty,
            .file => AssetFile,
        };
    }
};

pub const AssetFile = union(enum) {
    path: []const u8,
    // XXX: temporarily null terminated because we're storing zon here. eventually though, embedded zon
    // will be stored parsed not in string format, and we'll be able to stop zero terminating this.
    // XXX: does raise the question though--why does ast require null termination?
    data: [:0]const u8,
};

pub fn Descriptor(comptime source: AssetSource) type {
    return struct {
        id: []const u8,
        asset: source.instanceType(),
    };
}

pub fn index(comptime source: AssetSource, comptime descriptors: []const Descriptor(source)) type {
    const Instance = source.instanceType();

    comptime var ids: [descriptors.len]std.builtin.Type.EnumField = undefined;
    for (descriptors, &ids, 0..) |descriptor, *id, i| {
        id.* = .{
            .name = descriptor.id,
            .value = i,
        };
    }

    const Id_ = @Type(.{
        .Enum = .{
            .tag_type = @Type(std.builtin.Type{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = if (ids.len == 0) 0 else std.math.log2_int_ceil(usize, ids.len),
                },
            }),
            .fields = &ids,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });

    comptime var assets = std.EnumArray(Id_, Instance).initUndefined();
    for (descriptors, 0..) |descriptor, i| {
        comptime var asset = descriptor.asset;

        // If we're on a platform where `/` is not a valid path separator, replace it with the
        // native path separator.
        if (!std.fs.path.isSep('/') and asset == .path) {
            @setEvalBranchQuota(5000);
            comptime var path: [asset.path.len]u8 = asset.path[0..].*;
            std.mem.replaceScalar(u8, &path, '/', std.fs.path.sep);
            asset.path = &path;
        }

        assets.set(@enumFromInt(i), asset);
    }

    return struct {
        pub const Id = Id_;

        pub fn get(id: Id) *const Instance {
            return assets.getPtr(id);
        }
    };
}

test "basic index" {
    const expectEqual = std.testing.expectEqual;

    {
        const asset_index = index(.file, &.{
            .{
                .id = "foo",
                .asset = .{ .path = "bar" },
            },
            .{
                .id = "baz",
                .asset = .{ .data = "qux" },
            },
        });

        // Check the generated enum
        try expectEqual(@typeInfo(asset_index.Id).Enum.tag_type, u1);
        try expectEqual(@typeInfo(asset_index.Id).Enum.fields.len, 2);
        try expectEqual(@intFromEnum(asset_index.Id.foo), 0);
        try expectEqual(@intFromEnum(asset_index.Id.baz), 1);

        // Check the generated index
        try expectEqual(asset_index.get(.foo).path, "bar");
        try expectEqual(asset_index.get(.baz).data, "qux");
    }

    {
        const Asset = struct { x: u8 };
        const asset_index = index(.{ .value = Asset }, &.{
            .{
                .id = "foo",
                .asset = .{ .x = 10 },
            },
            .{
                .id = "baz",
                .asset = .{ .x = 20 },
            },
        });

        // Check the generated enum
        try expectEqual(@typeInfo(asset_index.Id).Enum.tag_type, u1);
        try expectEqual(@typeInfo(asset_index.Id).Enum.fields.len, 2);
        try expectEqual(@intFromEnum(asset_index.Id.foo), 0);
        try expectEqual(@intFromEnum(asset_index.Id.baz), 1);

        // Check the generated index
        try expectEqual(asset_index.get(.foo).*, .{ .x = 10 });
        try expectEqual(asset_index.get(.baz).*, .{ .x = 20 });
    }
}
