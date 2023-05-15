const std = @import("std");

fn Descriptor(comptime Asset: type) type {
    return struct {
        id: []const u8,
        asset: Asset,
    };
}

pub fn index(comptime Asset: type, comptime descriptors: []const Descriptor(Asset)) type {
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

    comptime var assets = std.EnumArray(Id_, Asset).initUndefined();
    for (descriptors, 0..) |descriptor, i| {
        assets.set(@enumFromInt(i), descriptor.asset);
    }

    return struct {
        pub const Id = Id_;

        pub fn get(id: Id) *const Asset {
            return assets.getPtr(id);
        }
    };
}

test "basic index" {
    const expectEqual = std.testing.expectEqual;

    const Asset = []const u8;
    const asset_index = index(Asset, &.{
        .{
            .id = "foo",
            .asset = "bar",
        },
        .{
            .id = "baz",
            .asset = "qux",
        },
    });

    // Check the generated enum
    try expectEqual(@typeInfo(asset_index.Id).Enum.tag_type, u1);
    try expectEqual(@typeInfo(asset_index.Id).Enum.fields.len, 2);
    try expectEqual(@intFromEnum(asset_index.Id.foo), 0);
    try expectEqual(@intFromEnum(asset_index.Id.baz), 1);

    // Check the generated index
    try expectEqual(asset_index.get(.foo).*, "bar");
    try expectEqual(asset_index.get(.baz).*, "qux");
}
