const std = @import("std");
const c = @import("c.zig");
const panic = std.debug.panic;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const display_width = 1920;
const display_height = 1080;

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    if (!(c.SDL_SetHintWithPriority(
        c.SDL_HINT_NO_SIGNAL_HANDLERS,
        "1",
        c.SDL_HINT_OVERRIDE,
    ) != c.SDL_FALSE)) {
        panic("failed to disable sdl signal handlers\n", .{});
    }
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMECONTROLLER) != 0) {
        panic("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    const window_mode = switch (builtin.mode) {
        .Debug => c.SDL_WINDOW_FULLSCREEN_DESKTOP,
        else => c.SDL_WINDOW_FULLSCREEN,
    };

    const screen = c.SDL_CreateWindow(
        "2Pew",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        display_width,
        display_height,
        window_mode,
    ) orelse {
        panic("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyWindow(screen);

    const renderer_flags: u32 = c.SDL_RENDERER_PRESENTVSYNC;
    const renderer: *c.SDL_Renderer = c.SDL_CreateRenderer(screen, -1, renderer_flags) orelse {
        panic("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyRenderer(renderer);

    var assets = try Assets.init(gpa, renderer);
    defer assets.deinit();

    const star_small = try assets.sprite("img/star/small.png");
    const star_large = try assets.sprite("img/star/large.png");

    var ship: Ship = .{
        .sprite = try assets.sprite("img/ship/ranger0.png"),
        .x = 500,
        .y = 500,
        .vel_x = 0,
        .vel_y = 0,
        .rotation = 0,
    };

    // sdlAssertZero(c.TTF_Init());

    var stars: [100]Star = undefined;
    generateStars(&stars);

    while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => return,
                c.SDL_KEYDOWN => switch (event.key.keysym.scancode) {
                    c.SDL_SCANCODE_ESCAPE => return,
                    else => {},
                },
                else => {},
            }
        }

        sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0x00, 0x00, 0x00, 0xff));
        sdlAssertZero(c.SDL_RenderClear(renderer));

        for (stars) |star| {
            const sprite = switch (star.kind) {
                .small => star_small,
                .large => star_large,
            };
            const dst_rect: c.SDL_Rect = .{
                .x = star.x,
                .y = star.y,
                .w = sprite.rect.w,
                .h = sprite.rect.h,
            };
            sdlAssertZero(c.SDL_RenderCopy(
                renderer,
                sprite.texture,
                null,
                &dst_rect,
            ));
        }

        {
            sdlAssertZero(c.SDL_RenderCopy(
                renderer,
                ship.sprite.texture,
                null,
                &ship.toSdlRect(),
            ));
        }

        c.SDL_RenderPresent(renderer);
    }
}

pub fn sdlAssertZero(ret: c_int) void {
    if (ret == 0) return;
    panic("sdl function returned an error: {s}", .{c.SDL_GetError()});
}

const Ship = struct {
    sprite: Sprite,
    /// pixels
    x: f32,
    y: f32,
    /// pixels per second
    vel_x: f32,
    vel_y: f32,
    /// radians
    rotation: f32,

    fn toSdlRect(s: Ship) c.SDL_Rect {
        return .{
            .x = @floatToInt(i32, @floor(s.x)),
            .y = @floatToInt(i32, @floor(s.y)),
            .w = s.sprite.rect.w,
            .h = s.sprite.rect.h,
        };
    }
};

const Sprite = struct {
    texture: *c.SDL_Texture,
    rect: c.SDL_Rect,
};

const Assets = struct {
    gpa: Allocator,
    renderer: *c.SDL_Renderer,
    dir: std.fs.Dir,

    fn init(gpa: Allocator, renderer: *c.SDL_Renderer) !Assets {
        const self_exe_dir_path = try std.fs.selfExeDirPathAlloc(gpa);
        defer gpa.free(self_exe_dir_path);
        const assets_dir_path = try std.fs.path.join(gpa, &.{ self_exe_dir_path, "assets" });
        defer gpa.free(assets_dir_path);
        var dir = std.fs.openDirAbsolute(assets_dir_path, .{}) catch |err| {
            panic("unable to open assets directory '{s}': {s}", .{
                assets_dir_path, @errorName(err),
            });
        };
        return .{
            .gpa = gpa,
            .renderer = renderer,
            .dir = dir,
        };
    }

    fn deinit(a: *Assets) void {
        a.dir.close();
        a.* = undefined;
    }

    fn sprite(a: *Assets, name: []const u8) !Sprite {
        const png_bytes = try a.dir.readFileAlloc(a.gpa, name, 50 * 1024 * 1024);
        defer a.gpa.free(png_bytes);
        return spriteBytes(png_bytes, a.renderer);
    }

    fn spriteBytes(png_data: []const u8, renderer: *c.SDL_Renderer) Sprite {
        var width: c_int = undefined;
        var height: c_int = undefined;
        const channel_count = 4;
        const bits_per_channel = 8;
        const image_data = c.stbi_load_from_memory(
            png_data.ptr,
            @intCast(c_int, png_data.len),
            &width,
            &height,
            null,
            channel_count,
        );
        const pitch = width * channel_count;
        const surface = c.SDL_CreateRGBSurfaceFrom(
            image_data,
            width,
            height,
            channel_count * bits_per_channel,
            pitch,
            0x000000ff,
            0x0000ff00,
            0x00ff0000,
            0xff000000,
        );
        const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse
            panic("unable to convert surface to texture", .{});
        return .{
            .texture = texture,
            .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        };
    }
};

const Star = struct {
    x: i32,
    y: i32,
    kind: Kind,

    const Kind = enum { large, small };
};

fn generateStars(stars: []Star) void {
    for (stars) |*star| {
        star.* = .{
            .x = std.crypto.random.uintAtMostBiased(u31, display_width),
            .y = std.crypto.random.uintAtMostBiased(u31, display_height),
            .kind = std.crypto.random.enumValue(Star.Kind),
        };
    }
}
