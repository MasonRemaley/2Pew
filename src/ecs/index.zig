// XXX: don't require extra namespacing..import stuff directly into here when applicable
pub const entities = @import("entities.zig");
pub const command_buffer = @import("command_buffer.zig");
pub const parenting = @import("parenting.zig");
pub const prefabs = @import("prefabs.zig");
pub const serializer = @import("serializer.zig");

test {
    _ = entities;
    _ = command_buffer;
    _ = prefabs;
    _ = serializer;
}
