const std = @import("std");
const c = @import("c.zig");
const panic = std.debug.panic;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const math = std.math;
const V = @import("Vec2d.zig");

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

    var players: [2]Player = .{
        .{
            .controller = null,
            .ship = 0,
        },
        .{
            .controller = null,
            .ship = 1,
        },
    };

    {
        var player_index: u32 = 0;
        for (0..@intCast(usize, c.SDL_NumJoysticks())) |i_usize| {
            const i = @intCast(u31, i_usize);
            if (c.SDL_IsGameController(i) != c.SDL_FALSE) {
                const sdl_controller = c.SDL_GameControllerOpen(i) orelse {
                    panic("SDL_GameControllerOpen failed: {s}\n", .{c.SDL_GetError()});
                };
                if (c.SDL_GameControllerGetAttached(sdl_controller) != c.SDL_FALSE) {
                    players[player_index].controller = sdl_controller;
                    player_index += 1;
                    if (player_index >= players.len) break;
                } else {
                    c.SDL_GameControllerClose(sdl_controller);
                }
            }
        }
    }

    const star_small = try assets.loadSprite("img/star/small.png");
    const star_large = try assets.loadSprite("img/star/large.png");
    const ship_sprite = try assets.loadSprite("img/ship/ranger0.png");
    const bullet_small = try assets.loadSprite("img/bullet/small.png");

    var ships = [_]Ship{
        .{
            .sprite = ship_sprite,
            .pos = .{ .x = 500, .y = 500 },
            .vel = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .rotation_speed = math.pi * 1.1,
            .thrust = 100,
            .cooldown = 0,
            .cooldown_amount = 0.2,
            .bullet_speed = 400,
            .bullet_duration = 0.5,
        },
        .{
            .sprite = ship_sprite,
            .pos = .{ .x = 1000, .y = 500 },
            .vel = .{ .x = 0, .y = 0 },
            .rotation = 0,
            .rotation_speed = math.pi * 1.1,
            .thrust = 100,
            .cooldown = 0,
            .cooldown_amount = 0.2,
            .bullet_speed = 400,
            .bullet_duration = 0.5,
        },
    };

    // sdlAssertZero(c.TTF_Init());

    var stars: [150]Star = undefined;
    generateStars(&stars);

    var bullets = std.ArrayList(Bullet).init(gpa);
    defer bullets.deinit();

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

        for (players) |player| {
            const ship = &ships[player.ship];
            ship.input = .{};
            if (player.controller) |controller| {
                // left/right on the left joystick
                const x_axis = c.SDL_GameControllerGetAxis(controller, c.SDL_CONTROLLER_AXIS_LEFTX);
                // up/down on the left joystick
                //const y_axis = c.SDL_GameControllerGetAxis(controller, c.SDL_CONTROLLER_AXIS_LEFTY);

                const dead_zone = 10000;
                ship.input.left = ship.input.left or x_axis < -dead_zone;
                ship.input.right = ship.input.right or x_axis > dead_zone;
                ship.input.forward = ship.input.forward or
                    c.SDL_GameControllerGetButton(controller, c.SDL_CONTROLLER_BUTTON_B) != 0;
                ship.input.fire = ship.input.fire or
                    c.SDL_GameControllerGetButton(controller, c.SDL_CONTROLLER_BUTTON_A) != 0;
                //std.debug.print("x_axis: {any} y_axis: {any}\n", .{ x_axis, y_axis });
                //std.debug.print("input: {any}\n", .{ship.input});
            }
        }

        const dt = 1.0 / 60.0;

        {
            var i: usize = 0;
            while (i < bullets.items.len) {
                const bullet = &bullets.items[i];

                bullet.pos.add(bullet.vel.scaled(dt));

                bullet.duration -= dt;
                if (bullet.duration <= 0) {
                    _ = bullets.swapRemove(i);
                    continue;
                }
                i += 1;
            }
        }

        for (&ships) |*ship| {
            ship.pos.add(ship.vel.scaled(dt));

            const rotate_input = // convert to 1.0 or -1.0
                @intToFloat(f32, @boolToInt(ship.input.right)) -
                @intToFloat(f32, @boolToInt(ship.input.left));
            ship.rotation = @mod(
                ship.rotation + rotate_input * ship.rotation_speed * dt,
                2 * math.pi,
            );

            // convert to 1.0 or 0.0
            const thrust_input = @intToFloat(f32, @boolToInt(ship.input.forward));
            const thrust = V.unit(ship.rotation);
            ship.vel.add(thrust.scaled(thrust_input * ship.thrust * dt));

            ship.cooldown -= dt;
            if (ship.input.fire and ship.cooldown <= 0) {
                ship.cooldown = ship.cooldown_amount;
                try bullets.append(.{
                    .sprite = bullet_small,
                    .pos = ship.pos,
                    .vel = V.unit(ship.rotation).scaled(ship.bullet_speed).plus(ship.vel),
                    .duration = ship.bullet_duration,
                    .radius = 2,
                });
            }
        }

        sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0x00, 0x00, 0x00, 0xff));
        sdlAssertZero(c.SDL_RenderClear(renderer));

        for (stars) |star| {
            const sprite = assets.sprite(switch (star.kind) {
                .small => star_small,
                .large => star_large,
            });
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

        for (ships) |ship| {
            const sprite = assets.sprite(ship.sprite);
            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer,
                sprite.texture,
                null, // source rectangle
                &sprite.toSdlRect(ship.pos),
                // The ship asset images point up instead of to the right.
                toDegrees(ship.rotation + math.pi / 2.0),
                null, // center of rotation
                c.SDL_FLIP_NONE,
            ));
        }

        for (bullets.items) |bullet| {
            const sprite = assets.sprite(bullet.sprite);
            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer,
                sprite.texture,
                null, // source rectangle
                &sprite.toSdlRect(bullet.pos),
                // The bullet asset images point up instead of to the right.
                toDegrees(bullet.vel.angle() + math.pi / 2.0),
                null, // center of rotation
                c.SDL_FLIP_NONE,
            ));
        }

        c.SDL_RenderPresent(renderer);
    }
}

pub fn sdlAssertZero(ret: c_int) void {
    if (ret == 0) return;
    panic("sdl function returned an error: {s}", .{c.SDL_GetError()});
}

const Player = struct {
    controller: ?*c.SDL_GameController,
    ship: u32,
};

const Bullet = struct {
    sprite: Sprite.Index,
    /// pixels
    pos: V,
    /// pixels per second
    vel: V,
    /// seconds
    duration: f32,
    /// pixels
    radius: f32,
};

const Ship = struct {
    sprite: Sprite.Index,
    /// pixels
    pos: V,
    /// pixels per second
    vel: V,
    /// radians
    rotation: f32,

    /// radians per second
    rotation_speed: f32,
    /// pixels per second squared
    thrust: f32,

    /// Player or AI decisions on what they want the ship to do.
    input: Input = .{},

    /// Seconds until ready. Less than or equal to 0 means ready.
    cooldown: f32,
    /// Seconds until ready. Cooldown is set to this after firing.
    cooldown_amount: f32,

    /// pixels per second
    bullet_speed: f32,
    /// seconds
    bullet_duration: f32,

    const Input = packed struct {
        fire: bool = false,
        forward: bool = false,
        left: bool = false,
        right: bool = false,
    };
};

const Sprite = struct {
    texture: *c.SDL_Texture,
    rect: c.SDL_Rect,

    /// Index into the sprites array.
    const Index = enum(u32) {
        _,
    };

    fn toSdlRect(sprite: Sprite, pos: V) c.SDL_Rect {
        return .{
            .x = @floatToInt(i32, @floor(pos.x)),
            .y = @floatToInt(i32, @floor(pos.y)),
            .w = sprite.rect.w,
            .h = sprite.rect.h,
        };
    }
};

const Assets = struct {
    gpa: Allocator,
    renderer: *c.SDL_Renderer,
    dir: std.fs.Dir,
    sprites: std.ArrayListUnmanaged(Sprite),

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
            .sprites = .{},
        };
    }

    fn deinit(a: *Assets) void {
        a.dir.close();
        a.sprites.deinit(a.gpa);
        a.* = undefined;
    }

    fn sprite(a: Assets, index: Sprite.Index) Sprite {
        return a.sprites.items[@enumToInt(index)];
    }

    fn loadSprite(a: *Assets, name: []const u8) !Sprite.Index {
        const png_bytes = try a.dir.readFileAlloc(a.gpa, name, 50 * 1024 * 1024);
        defer a.gpa.free(png_bytes);
        try a.sprites.append(a.gpa, spriteFromBytes(png_bytes, a.renderer));
        return @intToEnum(Sprite.Index, a.sprites.items.len - 1);
    }

    fn spriteFromBytes(png_data: []const u8, renderer: *c.SDL_Renderer) Sprite {
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

/// In this game we use (1, 0) as the 0-rotation vector.
/// In other words, 0 radians means pointing directly to the right.
/// (PI / 2) radians means (0, 1), or pointing directly down to the bottom of the screen.
/// SDL uses degrees (🤮), but at least it also uses clockwise rotation.
fn toDegrees(radians: f32) f32 {
    return 360.0 * (radians / (2 * math.pi));
}
