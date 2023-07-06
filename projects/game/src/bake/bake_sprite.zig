const c = @cImport({
    @cDefine("STBI_ONLY_PNG", "");
    @cDefine("STBI_NO_STDIO", "");
    @cInclude("stb_image.h");
});

const std = @import("std");

const Png = struct {
    const Self = @This();

    width: u16,
    height: u16,
    pixels: []u8,

    // XXX: can also give it a custom allocator if we really want (or is there a way to just give a buffer?)
    fn init(encoded: []u8) Self {
        var width: c_int = undefined;
        var height: c_int = undefined;
        const channel_count = 4;
        const pixels = c.stbi_load_from_memory(
            encoded.ptr,
            @intCast(encoded.len),
            &width,
            &height,
            null,
            channel_count,
        );
        return .{
            .width = @intCast(width),
            .height = @intCast(height),
            .pixels = pixels[0 .. @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * channel_count],
        };
    }

    fn deinit(self: *Self) void {
        c.stbi_image_free(self.pixels.ptr);
        self.* = undefined;
    }
};

pub fn main() !void {
    // XXX: allocator...never free memory this is a short lived process?
    // XXX: reader used on pngs is buffered right?
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Get the arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 5) {
        std.debug.print("expected 4 arguments \n", .{});
        return error.BadArgCount;
    }

    const Tint = union(enum) {
        mask: Png,
        luminosity,
        none,
    };

    const diffuse_path = args[1];
    const tint_str = args[2];
    const degrees = try std.fmt.parseFloat(f32, args[3]);
    const out_path = args[4];

    // XXX: is cwd right, or does running zig from different places break this?
    // Bake the sprite
    var dir = std.fs.cwd();

    var diffuse = b: {
        var bytes = try dir.readFileAlloc(allocator, diffuse_path, 50 * 1024 * 1024);
        defer allocator.free(bytes);
        break :b Png.init(bytes);
    };
    defer diffuse.deinit();

    var tint: Tint = if (std.mem.endsWith(u8, tint_str, ".png")) b: {
        var bytes = try dir.readFileAlloc(allocator, tint_str, 50 * 1024 * 1024);
        defer allocator.free(bytes);
        break :b .{ .mask = Png.init(bytes) };
    } else if (std.mem.eql(u8, tint_str, "luminosity"))
        .luminosity
    else if (std.mem.eql(u8, tint_str, "none"))
        .none
    else
        std.debug.panic("unexpected tint argument: {s}", .{tint_str});
    defer if (tint == .mask) tint.mask.deinit();

    // XXX: read/write file options?
    // XXX: are we ever gonna add other fields to the id files or just make string? also rename extension to id??
    // XXX: include tint too if not a mask and not applied here!!
    var out_file = try dir.createFile(out_path, .{});
    defer out_file.close();
    var out_file_writer = out_file.writer();
    try out_file_writer.writeIntLittle(u16, diffuse.width);
    try out_file_writer.writeIntLittle(u16, diffuse.height);
    // XXX: or just apply the rotation here? (can limit to 90 degree increments...)
    // XXX: why can't u32 be inferred here?
    try out_file_writer.writeIntLittle(u32, @as(u32, @bitCast(degrees)));
    // XXX: could use an enum...
    switch (tint) {
        .mask => try out_file_writer.writeIntLittle(u8, 2),
        .luminosity => try out_file_writer.writeIntLittle(u8, 1),
        .none => try out_file_writer.writeIntLittle(u8, 0),
    }
    try out_file_writer.writeAll(diffuse.pixels);
    if (tint == .mask) {
        if (tint.mask.width != diffuse.width or tint.mask.height != diffuse.height) {
            std.debug.print("diffuse and mask dimensions do not match\n", .{});
            return error.InvalidMask;
        }
        try out_file_writer.writeAll(tint.mask.pixels);
    }
}
