// XXX: test this module?
// XXX: allow speicfying the same input asset with different bake settings multiple times?
// XXX: what about e.g. deleting an asset that wasn't yet released? we could have a way to mark them as such maye idk, on release
// it can change whether they need to be persistent
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
        assets.set(@intToEnum(Id_, i), descriptor.asset);
    }

    return struct {
        pub const Id = Id_;

        pub fn get(id: Id) Asset {
            return assets.get(id);
        }
    };
}
