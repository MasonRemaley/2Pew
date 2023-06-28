// XXX: can i delete this now?
// XXX: problem:
// - this scheme depends on files without telling the build system
// - we can just differentiate between images and sprites
// - the problem with this is that we'd need to make way more json files,
// one for each image, which is annoying. however...we could make like
// .sprite.png files automatically be sprites AND images as a shortcut. if you wanna
// combine multiple images then you gotta not.
// - do we need to allow for multiple extensions, or do we need to allow for combining
// indices? I mean both in the end but yeah figure out how to start on this!

const c = @cImport({
    @cDefine("STBI_ONLY_PNG", "");
    @cDefine("STBI_NO_STDIO", "");
    @cInclude("stb_image.h");
});

const std = @import("std");
// const zon = @import("zon");
// XXX: these deps okay..?
// const asset_index = @import("asset_index.zig");
// const asset_indexer = @import("asset_indexer.zig");
// const Animation = asset_index.Animation;
// const Descriptor = asset_indexer.Descriptor;

// XXX: naming...
// XXX: rename to persistent_id so it's clear you shouldn't change it?
// XXX: would kinda make more sense if sprites were assets made of images, but then for the simple case
// where there's only a single image it's annoying...we could make a flag you can change on an image to make
// it a sprite but that's still annoying...
// XXX: error on any unused masks?
// XXX: add angle and bake in the change? can make it a 90 degree increment only sorta thing if that's easier--just
// specify the up direction or something
// XXX: remove img/ and anim/ prefixes from ids, not useful, also remove extensions..also organize to object instead of file type!
const BakeConfig = struct {
    id: []const u8,
    // XXX: set kevin to 45 degrees to see if actually affects anything. make sure that editing json
    // also causes files to update but WAIT. this setup is wrong in that it won't auto update if the
    // mask file changes, because it's not away that this depends on the mask file!
    // XXX: wait also it's just like, getting the right value even though it's set to 45??
    // XXX: but in general, this is wrong, in that it only knows when the one file changes.
    // XXX: we COULD just do the thing where we have a .sprite file for each sprite. but for it to
    // work right, it can't actually do any baking, just specify connections between existing images.
    // if it starts baking them together then it's adding untracked dependencies. that also means it can't
    // easily assert that the sizes line up while baking at least not from here?
    // XXX: if we wantd to be able to do more..we'd need a way to communicate dependencies to the baker. idk if we
    // actually want that kinda complexity though.
    // XXX: don't actually need degrees here, it's on sprite now
    // degrees: f32 = 0.0,
    // XXX: have a luminosity_tint field that tints based on luminosity or something? but in general if there's a mask use it!
    // tint: ?struct {
    //     mask: ?[]const u8 = null,
    // } = null,
};

// XXX: allow writing out directly to where we want? or i guess we don't know the size yet..
// but there's probably a way to read it!
// XXX: only created cause i was loading more than one but maybe still useful?
const Png = struct {
    const Self = @This();

    width: u16,
    height: u16,
    pixels: []u8,

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

// XXX: move to main src, figure out how to isolate, maybe move some of the build logic into a function in here
// XXX: never free memory here it's a short lived process, just use a fixed buffer allocator from some pages or something
// XXX: this reader is buffered right?
// XXX: use arena or some kinda bump allocator since it's short lived?
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Get the paths
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.debug.panic("expected 2 arguments", .{});
    }

    const in_path = args[1];
    const out_path = args[2];

    // XXX: is cwd correct here, or does running zig build from different places mess it up?
    var dir = std.fs.cwd();

    // XXX: we'll use this eventually for tinting
    // var zon_source = try dir.readFileAllocOptions(
    //     allocator,
    //     zon_path,
    //     128,
    //     null,
    //     @alignOf(u8),
    //     0,
    // );
    // defer allocator.free(zon_source);
    // // XXX: show good errors on failure! does it already show filename from build system?
    // const config = zon.parseFromSlice(BakeConfig, allocator, zon_source) catch |err| {
    //     std.debug.print("failed to parse: {s}\n", zon_source);
    //     return err;
    // };
    // defer zon.parseFree(allocator, config);

    // Bake the texture
    var png = try dir.readFileAlloc(allocator, in_path, 50 * 1024 * 1024);

    // XXX: can also give it a custom allocator if we really want (or is there a way to just give a buffer?)
    var decoded = Png.init(png);
    defer decoded.deinit();

    // XXX: remove...
    // XXX: do all in block return single optional
    // var mask_path = try std.fmt.allocPrint(allocator, "{s}.mask.png", .{in_path[0 .. in_path.len - std.fs.path.extension(in_path).len]});
    // var mask_encoded: ?[]u8 = dir.readFileAlloc(allocator, mask_path, 50 * 1024 * 1024) catch |err| switch (err) {
    //     // XXX: why need error prefix?
    //     error.FileNotFound => null,
    //     else => return err,
    // };
    // defer if (mask_encoded) |m| allocator.free(m);
    // var mask_decoded = if (mask_encoded) |m| Png.init(m) else null;
    // defer if (mask_decoded) |*m| m.deinit();

    // // XXX: error handling...
    // if (mask_decoded) |m| {
    //     if (m.width != decoded.width or m.height != decoded.height) {
    //         @panic("dimensions of mask to not match");
    //     }
    // }

    // XXX: options?
    var out_file = try dir.createFile(out_path, .{});
    defer out_file.close();
    // XXX: could also write to a buffer in memory then write to the file in one go? we even know how big it is
    // up front etc...
    var out_file_writer = out_file.writer();

    // XXX: can/should I do this in one write?
    // XXX: make not depend on endianness
    // XXX: how does write struct handle arrays?
    // XXX: ooh neat we can use writeIntLittle/writeIntBig, there's probably a reader interface to get it back
    // on the other side too.
    // XXX: we might also be able to use writestruct (if it handles this) to read/write a header, and then just have all
    // the following data after that fixed header be the rest!
    try out_file_writer.writeAll(&(@as([2]u8, @bitCast(decoded.width)) ++ @as([2]u8, @bitCast(decoded.height))));
    // XXX: we could actually write an enum as a number here if we had a library for this format!
    // if (config.value.tint) |tint| {
    //     if (tint.mask == null) {
    //         try out_file_writer.writeByte(1);
    //     } else {
    //         try out_file_writer.writeByte(2);
    //     }
    // } else {
    //     try out_file_writer.writeByte(0);
    // }
    // XXX: specify in degrees but convert to radians on bake?
    // const radians = std.math.degreesToRadians(f32, config.degrees);
    // try out_file_writer.writeAll(&@bitCast([4]u8, radians));
    // try out_file_writer.writeByte(if (mask_decoded == null) 0 else 1);
    try out_file_writer.writeAll(decoded.pixels);
    // if (mask_decoded) |m| {
    //     try out_file_writer.writeAll(m.pixels);
    // }
}
