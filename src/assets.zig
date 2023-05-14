const std = @import("std");

fn AssetDescriptor(comptime Asset: type) type {
    return struct {
        id: []const u8,
        asset: Asset,
    };
}

// XXX: anything in assets to test..?
pub fn generate(comptime Asset: type, comptime descriptors: []const AssetDescriptor(Asset)) type {
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

    comptime var assets_ = std.EnumArray(Id_, Asset).initUndefined();
    for (descriptors, 0..) |descriptor, i| {
        assets_.set(@intToEnum(Id_, i), descriptor.asset);
    }

    return struct {
        pub const Id = Id_;
        pub const assets = assets_;
    };
}
