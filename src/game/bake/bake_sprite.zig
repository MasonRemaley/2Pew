const std = @import("std");

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
        std.debug.panic("expected two arguments", .{});
    }

    const in_path = args[1];
    const out_path = args[2];

    // XXX: pass in th id directly so we don't need to parse if the build script already parsed that anyway?
    // XXX: just pass in the json path as well...silly to have to do this in ever baker AND less
    // encapsulated since it now depends on the outside calling it on files that line up
    // XXX: rename to config to options or bake options or bake config or such?
    const json_path = try std.fmt.allocPrint(allocator, "{s}.json", .{in_path});

    // XXX: is cwd correct here, or does running zig build from different places mess it up?
    var dir = std.fs.cwd();

    // XXX: we'll use this eventually for tinting
    var json_file = try dir.openFile(json_path, .{});
    defer json_file.close();
    var json_reader = std.json.reader(allocator, json_file.reader());
    defer json_reader.deinit();
    var config = try std.json.parseFromTokenSource(BakeConfig, allocator, &json_reader, .{
        // XXX: ?
        .ignore_unknown_fields = true,
    });
    defer config.deinit();

    // XXX: options?
    var out_file = try dir.createFile(out_path, .{});
    defer out_file.close();
    // XXX: could also write to a buffer in memory then write to the file in one go? we even know how big it is
    // up front etc...
    var out_file_writer = out_file.writer();
    try out_file_writer.writeAll(
        \\pub const asset = .{
        \\    .diffuse = .@"
    );
    // XXX: have to escape quotes in the id...may also be also be a way to generate zon from zig
    // automatically which would be better!
    try out_file_writer.writeAll(config.value.id);
    try out_file_writer.writeAll(
        \\",
        \\};
    );
}
