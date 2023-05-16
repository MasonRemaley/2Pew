const std = @import("std");
// XXX: these deps okay..?
// const asset_index = @import("asset_index.zig");
// const asset_indexer = @import("asset_indexer.zig");
// const Animation = asset_index.Animation;
// const Descriptor = asset_indexer.Descriptor;

const BakeConfig = struct { id: []const u8 };

// XXX: move to main src, figure out how to isolate, maybe move some of the build logic into a function in here
// XXX: never free memory here it's a short lived process, just use a fixed buffer allocator from some pages or something
// XXX: this reader is buffered right?
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 4) {
        std.debug.panic("expected three arguments", .{});
    }

    const json_path = args[1];
    const zig_path = args[2];
    const out_path = args[3];

    var file = try std.fs.openFileAbsolute(json_path, .{});
    defer file.close();
    var source = try file.readToEndAlloc(allocator, 1000000);
    var tokens = std.json.TokenStream.init(source);
    const parse_options = .{ .allocator = allocator };
    var config = try std.json.parse(BakeConfig, &tokens, parse_options);
    defer std.json.parseFree(BakeConfig, config, parse_options);

    // XXX: rename to persistent_id so it's clear you shouldn't change it?
    std.debug.print("bake id {s}\n", .{config.id});
    std.debug.print("zig {s}\n", .{zig_path});
    std.debug.print("output! {s}\n", .{out_path});

    // XXX: options?
    try std.fs.copyFileAbsolute(zig_path, out_path, .{});
}
