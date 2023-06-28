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

    if (args.len != 3) {
        std.debug.panic("expected 2 arguments", .{});
    }

    // XXX: pass in th id directly so we don't need to parse if the build script already parsed that anyway?
    // XXX: kinda weird that the asset path is a file that doesn't exist? could change order and skip if doesn't
    // exist to reflect idk
    const zon_path = args[1];
    const out_path = args[2];

    // XXX: is cwd correct here, or does running zig build from different places mess it up?
    var dir = std.fs.cwd();

    // XXX: we'll use this eventually for tinting
    // XXX: ignore unknown fields? pass in id directly vs passing in zon file? makes sense depending on if used or not i guess
    var zon_source = try dir.readFileAllocOptions(
        allocator,
        zon_path,
        128,
        null,
        @alignOf(u8),
        0,
    );
    defer allocator.free(zon_source);
    // XXX: show good errors on failure! does it already show filename from build system?
    const config = try zon.parseFromSlice(BakeConfig, allocator, zon_source, .{});
    defer zon.parseFree(allocator, config);

    // XXX: options?
    var out_file = try dir.createFile(out_path, .{});
    defer out_file.close();
    // XXX: could also write to a buffer in memory then write to the file in one go? we even know how big it is
    // up front etc...
    var out_file_writer = out_file.writer();
    try out_file_writer.writeAll(
        \\.{
        \\    .diffuse = .@"
    );
    // XXX: have to escape quotes in the id...may also be also be a way to generate zon from zig
    // automatically which would be better!
    try out_file_writer.writeAll(config.id);
    // XXX: ...
    try out_file_writer.writeAll(
        \\",
        \\    .diffuse_path = "unimplemented",
        \\}
    );
}
