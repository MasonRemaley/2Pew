const std = @import("std");

// XXX: move to main src, figure out how to isolate, maybe move some of the build logic into a function in here
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    // std.debug.print("Out path: {s}\n", .{args[1..]});

    // const input = args[1];
    // const output = args[2];

    std.debug.print("baking {}\n", .{args.len});
    const output = args[1];
    std.debug.print("running bake step! {s}\n", .{output});

    // _ = input;

    // var dir = try std.fs.openDirAbsolute(output, .{});
    // defer dir.close();
    // try dir.makeDir("My Directory");

    // XXX: make a new id enum for each asset type? easier to write apis for!
    const value = "pub const AssetId = enum { foo, bar };\n";

    var my_file = try std.fs.createFileAbsolute(output, .{ .read = true });
    defer my_file.close();

    try my_file.writeAll(value);

    std.debug.print("done!\n", .{});
}
