pub const ecs = @import("ecs/ecs.zig");
pub const asset_indexer = @import("asset_indexer.zig");
pub const input_system = @import("input_system.zig");
pub const minimum_alignment_allocator = @import("minimum_alignment_allocator.zig");
pub const no_alloc = @import("no_alloc.zig");
pub const segmented_list = @import("segmented_list.zig");
pub const slot_map = @import("slot_map.zig");
pub const symmetric_matrix = @import("symmetric_matrix.zig");
pub const bake = @import("bake/index.zig");
pub const c = @import("c.zig");

// XXX: make sure these still get run!
test {
    _ = @import("asset_indexer.zig");
    _ = @import("slot_map.zig");
    _ = @import("minimum_alignment_allocator.zig");
    _ = @import("ecs/ecs.zig");
    _ = @import("segmented_list.zig");
    _ = @import("symmetric_matrix.zig");
    _ = @import("bake/index.zig");
}
