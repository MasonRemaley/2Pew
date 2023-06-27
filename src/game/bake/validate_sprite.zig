const std = @import("std");
const zon = @import("zon");

const BakeConfig = struct {
    id: []const u8,
};

pub fn main() !void {
    // XXX: allocator...
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Get the paths
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.debug.panic("expected 1 argument", .{});
    }

    // XXX: implement...pass in the diffuse and mask not the config cause we need to reference the
    // actual files for the build system to understand!
    const zon_path = args[1];
    std.debug.print("validate {s}\n", .{zon_path});
}
