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
    // XXX: allocator...
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Get the arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 5) {
        std.debug.print("expected 4 arguments \n", .{});
        return error.BadArgCount;
    }

    const diffuse_path = args[1];
    const tint = args[2];
    const degrees = try std.fmt.parseFloat(f32, args[3]);
    const out_path = args[4];

    // Bake the sprite
    var dir = std.fs.cwd();

    var diffuse = b: {
        var bytes = try dir.readFileAlloc(allocator, diffuse_path, 50 * 1024 * 1024);
        defer allocator.free(bytes);
        break :b Png.init(bytes);
    };
    defer diffuse.deinit();

    var mask = if (std.mem.endsWith(u8, tint, ".png")) b: {
        var bytes = try dir.readFileAlloc(allocator, tint, 50 * 1024 * 1024);
        defer allocator.free(bytes);
        break :b Png.init(bytes);
    } else null;
    defer if (mask) |*m| m.deinit();

    // XXX: include tint too if not a mask and not applied here!!
    var out_file = try dir.createFile(out_path, .{});
    defer out_file.close();
    var out_file_writer = out_file.writer();
    try out_file_writer.writeIntLittle(u32, diffuse.width);
    try out_file_writer.writeIntLittle(u32, diffuse.height);
    // XXX: or just apply the rotation here? (can limit to 90 degree increments...)
    // XXX: why can't u32 be inferred here?
    try out_file_writer.writeIntLittle(u32, @as(u32, @bitCast(degrees)));
    try out_file_writer.writeAll(diffuse.pixels);
    if (mask) |m| {
        if (m.width != diffuse.width or m.height != diffuse.height) {
            std.debug.print("diffuse and mask dimensions do not match\n", .{});
            return error.InvalidMask;
        }
        try out_file_writer.writeAll(m.pixels);
    }
}
