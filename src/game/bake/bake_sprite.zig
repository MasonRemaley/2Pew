const c = @cImport({
    @cDefine("STBI_ONLY_PNG", "");
    @cDefine("STBI_NO_STDIO", "");
    @cInclude("stb_image.h");
});

// XXX: delete this or replace with real bake step once the basics work!
// XXX: test reading stuff from the json eventually!
// XXX: don't name file this way unless it's a struct

const std = @import("std");
// XXX: these deps okay..?
// const asset_index = @import("asset_index.zig");
// const asset_indexer = @import("asset_indexer.zig");
// const Animation = asset_index.Animation;
// const Descriptor = asset_indexer.Descriptor;

// const BakeConfig = struct { id: []const u8 };

// XXX: move to main src, figure out how to isolate, maybe move some of the build logic into a function in here
// XXX: never free memory here it's a short lived process, just use a fixed buffer allocator from some pages or something
// XXX: this reader is buffered right?
// XXX: use arena or some kinda bump allocator since it's short lived?
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.debug.panic("expected two arguments", .{});
    }

    const in_path = args[1];
    const out_path = args[2];

    // XXX: is cwd correct here, or does running zig build from different places mess it up?
    var dir = std.fs.cwd();

    var png = try dir.readFileAlloc(allocator, in_path, 50 * 1024 * 1024);

    // XXX: can also give it a custom allocator if we really want (or is there a way to just give a buffer?)
    var width_u: c_int = undefined;
    var height_u: c_int = undefined;
    const channel_count = 4;
    const decoded_array = c.stbi_load_from_memory(
        png.ptr,
        @intCast(png.len),
        &width_u,
        &height_u,
        null,
        channel_count,
    );
    defer c.stbi_image_free(decoded_array);

    const width: u16 = @intCast(width_u);
    const height: u16 = @intCast(height_u);
    const len = @as(usize, width) * @as(usize, height) * @as(usize, channel_count);
    const decoded = decoded_array[0..len];

    var out_file = try dir.createFile(out_path, .{});
    defer out_file.close();

    // XXX: can/should I do this in one write?
    // XXX: make not depend on endianness
    try out_file.writeAll(&(@as([2]u8, @bitCast(width)) ++ @as([2]u8, @bitCast(height))));
    try out_file.writeAll(decoded);

    // XXX: we'll use this eventually for tinting
    // var file = try std.fs.openFileAbsolute(json_path, .{});
    // defer file.close();
    // var source = try file.readToEndAlloc(allocator, 1000000);
    // var tokens = std.json.TokenStream.init(source);
    // const parse_options = .{ .allocator = allocator };
    // var config = try std.json.parse(BakeConfig, &tokens, parse_options);
    // defer std.json.parseFree(BakeConfig, config, parse_options);

    // // XXX: rename to persistent_id so it's clear you shouldn't change it?
    // std.debug.print("bake id {s}\n", .{config.id});
    // std.debug.print("zig {s}\n", .{in_path});
    // std.debug.print("output! {s}\n", .{out_path});

    // XXX: options?
    // try dir.copyFile(in_path, dir, out_path, .{});
}
