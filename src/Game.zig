const std = @import("std");
const gpu = @import("gpu");
const zcs = @import("zcs");
const tracy = @import("tracy");
const c = @import("c.zig").c;
const Assets = @import("Assets.zig");
const Renderer = @import("Renderer.zig");
const Trauma = @import("Trauma.zig");
const Rumble = @import("Rumble.zig");

const Animation = Assets.Animation;
const Sprite = Assets.Sprite;
const Vec2 = zcs.ext.geom.Vec2;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const CmdBuf = zcs.CmdBuf;
const Node = zcs.ext.Node;
const Transform = zcs.ext.Transform2D;
const Allocator = std.mem.Allocator;
const Zone = tracy.Zone;
const ImageUploadQueue = gpu.ext.ImageUploadQueue;
const Gx = gpu.Gx;
const Random = std.Random;
const ModTimer = gpu.ext.ModTimer;
const RenderTarget = gpu.ext.RenderTarget;

const log = std.log;
const math = std.math;
const tween = zcs.ext.geom.tween;
const lerp = tween.interp.lerp;
const remap = tween.interp.remap;

pub const display_size: Vec2 = .{ .x = 1920, .y = 1080 };
pub const display_center = display_size.scaled(0.5);
pub const display_radius = display_size.y / 2.0;
pub const dead_zone = 10000;

const SymmetricMatrix = @import("symmetric_matrix.zig").SymmetricMatrix;

const Game = @This();

gx: *Gx,
es: *Entities,
assets: *Assets,
renderer: *Renderer,
// Only used for debug purposes.
debug_allocator: Allocator,
hot_swap: bool = false,

ease_t: f32 = 0.0,

controllers: [4]?*c.SDL_Gamepad = .{ null, null, null, null },
control_schemes: [4]input_system.ControlScheme,
input_state: [4]input_system.InputState,
teams_buffer: [4]Team,
teams: []Team,

shrapnel_animations: [shrapnel_sprite_names.len]Animation.Index,
explosion_animation: Animation.Index,

ring_bg: Sprite.Index,
star_small: Sprite.Index,
star_large: Sprite.Index,
planet_red: Sprite.Index,
bullet_small: Sprite.Index,
bullet_shiny: Sprite.Index,

rock_sprites: [rock_sprite_names.len]Sprite.Index,

ranger_animations: ShipAnimations,
ranger_radius: f32,

militia_animations: ShipAnimations,
militia_radius: f32,

triangle_animations: ShipAnimations,
triangle_radius: f32,

kevin_animations: ShipAnimations,
kevin_radius: f32,

wendy_animations: ShipAnimations,
wendy_radius: f32,

stars: [900]Star,

particle: Sprite.Index,

rng: std.Random,

camera: Vec2 = display_size.scaled(-0.5),
timer: ModTimer = .{},

global_trauma: Trauma = .init(.{}),
player_trauma: [4]Trauma = @splat(.init(.{})),
rumble: Rumble = .{},

color_buffer: RenderTarget(.color),
composite: RenderTarget(.color),
blurred: [2]RenderTarget(.color),
window_extent: gpu.Extent2D,
resize_timer: std.time.Timer,

const ShipAnimations = struct {
    still: Animation.Index,
    accel: Animation.Index,
    thrusters_left: ?Animation.Index = null,
    thrusters_right: ?Animation.Index = null,
    thrusters_top: ?Animation.Index = null,
    thrusters_bottom: ?Animation.Index = null,
};

const shrapnel_sprite_names = [_][:0]const u8{
    "img/shrapnel/01.png",
    "img/shrapnel/02.png",
    "img/shrapnel/03.png",
};

const rock_sprite_names = [_][:0]const u8{
    "img/rock-a.png",
    "img/rock-b.png",
    "img/rock-c.png",
};

fn createRanger(
    self: *const @This(),
    cb: *CmdBuf,
    player_index: PlayerIndex,
    team_index: TeamIndex,
    pos: Vec2,
    angle: f32,
) void {
    const ship = Entity.reserve(cb);
    ship.add(cb, Node, .{});
    ship.add(cb, Ship, .{
        .class = .ranger,
        .turn_speed = math.pi * 1.0,
        .thrust = 160,
    });
    ship.add(cb, Health, .{
        .hp = 80,
        .max_hp = 80,
    });
    ship.add(cb, Transform, .{
        .pos = pos,
        .rot = .fromAngle(angle),
    });
    ship.add(cb, RigidBody, .{
        .vel = .zero,
        .radius = self.ranger_radius,
        .rotation_vel = 0.0,
        .density = 0.02,
    });
    ship.add(cb, Collider, .{
        .collision_damping = 0.4,
        .layer = .vehicle,
    });
    ship.add(cb, Animation.Playback, .{
        .index = self.ranger_animations.still,
    });
    ship.add(cb, PlayerIndex, player_index);
    ship.add(cb, TeamIndex, team_index);
    ship.add(cb, Turret, .{
        .radius = self.ranger_radius,
        .cooldown = .{ .time = .{ .max_s = 0.1 } },
        .projectile_speed = 550,
        .projectile_lifetime = 1.0,
        .projectile_damage = 6,
        .projectile_radius = 8,
    });

    const thruster = Entity.reserve(cb);
    thruster.add(cb, Transform, .{});
    thruster.add(cb, RigidBody, .{
        .radius = self.ranger_radius,
        .density = std.math.inf(f32),
    });
    thruster.add(cb, AnimateOnInput, .{
        .action = .thrust_forward,
        .direction = .positive,
        .activated = self.ranger_animations.accel,
        .deactivated = .none,
    });
    thruster.add(cb, Animation.Playback, .{ .index = .none });
    thruster.add(cb, PlayerIndex, player_index);
    cb.ext(Node.SetParent, .{ .child = thruster, .parent = ship.toOptional() });
}

fn createTriangle(
    self: *const @This(),
    cb: *CmdBuf,
    player_index: PlayerIndex,
    team_index: TeamIndex,
    pos: Vec2,
    angle: f32,
) void {
    const radius = 24;
    const ship = Entity.reserve(cb);
    ship.add(cb, Ship, .{
        .class = .triangle,
        .turn_speed = math.pi * 0.9,
        .thrust = 250,
    });
    ship.add(cb, Health, .{
        .hp = 100,
        .max_hp = 100,
        .regen_ratio = 0.5,
    });
    ship.add(cb, Transform, .{
        .pos = pos,
        .rot = .fromAngle(angle),
    });
    ship.add(cb, RigidBody, .{
        .vel = .zero,
        .radius = 26,
        .rotation_vel = 0.0,
        .density = 0.02,
    });
    ship.add(cb, Collider, .{
        .collision_damping = 0.4,
        .layer = .vehicle,
    });
    ship.add(cb, Animation.Playback, .{
        .index = self.triangle_animations.still,
    });
    ship.add(cb, PlayerIndex, player_index);
    ship.add(cb, TeamIndex, team_index);
    ship.add(cb, Turret, .{
        .radius = radius,
        .cooldown = .{ .time = .{ .max_s = 0.2 } },
        .projectile_speed = 700,
        .projectile_lifetime = 1.0,
        .projectile_damage = 12,
        .projectile_radius = 12,
    });

    const thruster = Entity.reserve(cb);
    thruster.add(cb, Transform, .{});
    thruster.add(cb, RigidBody, .{
        .radius = self.militia_radius,
        .density = std.math.inf(f32),
    });
    thruster.add(cb, AnimateOnInput, .{
        .action = .thrust_forward,
        .direction = .positive,
        .activated = self.triangle_animations.accel,
        .deactivated = .none,
    });
    thruster.add(cb, Animation.Playback, .{ .index = .none });
    thruster.add(cb, PlayerIndex, player_index);
    cb.ext(Node.SetParent, .{ .child = thruster, .parent = ship.toOptional() });
}

fn createMilitia(
    self: *const @This(),
    cb: *CmdBuf,
    player_index: PlayerIndex,
    team_index: TeamIndex,
    pos: Vec2,
    angle: f32,
) void {
    const ship = Entity.reserve(cb);
    ship.add(cb, Node, .{});
    ship.add(cb, Ship, .{
        .class = .militia,
        .turn_speed = math.pi * 1.4,
        .thrust = 400,
    });
    ship.add(cb, Health, .{
        .hp = 80,
        .max_hp = 80,
    });
    ship.add(cb, Transform, .{
        .pos = pos,
        .rot = .fromAngle(angle),
    });
    ship.add(cb, RigidBody, .{
        .vel = .zero,
        .rotation_vel = 0.0,
        .radius = self.militia_radius,
        .density = 0.06,
    });
    ship.add(cb, Collider, .{
        .collision_damping = 0.4,
        .layer = .vehicle,
    });
    ship.add(cb, Animation.Playback, .{
        .index = self.militia_animations.still,
    });
    // .grapple_gun = .{
    //     .radius = self.ranger_radius * 10.0,
    //     .angle = 0,
    //     .cooldown_s = 0,
    //     .max_cooldown_s = 0.2,
    //     // TODO: when nonzero, causes the ship to move. wouldn't happen if there was equal
    //     // kickback!
    //     .projectile_speed = 0,
    // },
    ship.add(cb, PlayerIndex, player_index);
    ship.add(cb, TeamIndex, team_index);
    ship.add(cb, FrontShield, .{});

    const thruster = Entity.reserve(cb);
    thruster.add(cb, Transform, .{});
    thruster.add(cb, RigidBody, .{
        .radius = self.militia_radius,
        .density = std.math.inf(f32),
    });
    thruster.add(cb, AnimateOnInput, .{
        .action = .thrust_forward,
        .direction = .positive,
        .activated = self.militia_animations.accel,
        .deactivated = .none,
    });
    thruster.add(cb, Animation.Playback, .{ .index = .none });
    thruster.add(cb, PlayerIndex, player_index);
    cb.ext(Node.SetParent, .{ .child = thruster, .parent = ship.toOptional() });
}

fn createKevin(
    self: *const @This(),
    cb: *CmdBuf,
    player_index: PlayerIndex,
    team_index: TeamIndex,
    pos: Vec2,
    angle: f32,
) void {
    const radius = 32;
    const ship = Entity.reserve(cb);
    ship.add(cb, Node, .{});
    ship.add(cb, Ship, .{
        .class = .kevin,
        .turn_speed = math.pi * 1.1,
        .thrust = 300,
    });
    ship.add(cb, Health, .{
        .hp = 300,
        .max_hp = 300,
    });
    ship.add(cb, Transform, .{
        .pos = pos,
        .rot = .fromAngle(angle),
    });
    ship.add(cb, RigidBody, .{
        .vel = .zero,
        .radius = radius,
        .rotation_vel = 0.0,
        .density = 0.02,
    });
    ship.add(cb, Collider, .{
        .collision_damping = 0.4,
        .layer = .vehicle,
    });
    ship.add(cb, Animation.Playback, .{
        .index = self.kevin_animations.still,
    });
    ship.add(cb, PlayerIndex, player_index);
    ship.add(cb, TeamIndex, team_index);

    for ([2]f32{ -20.0, 20.0 }) |y| {
        const turret = Entity.reserve(cb);
        turret.add(cb, Turret, .{
            .radius = 32,
            .cooldown = .{ .time = .{ .max_s = 0.2 } },
            .projectile_speed = 500,
            .projectile_lifetime = 1.0,
            .projectile_damage = 18,
            .projectile_radius = 18,
        });
        turret.add(cb, PlayerIndex, player_index);
        turret.add(cb, TeamIndex, team_index);
        turret.add(cb, Transform, .{
            .pos = .{ .x = 0.0, .y = y },
        });
        cb.ext(Node.SetParent, .{ .child = turret, .parent = ship.toOptional() });
    }

    const thruster = Entity.reserve(cb);
    cb.ext(Node.SetParent, .{ .child = thruster, .parent = ship.toOptional() });
    thruster.add(cb, Transform, .{});
    thruster.add(cb, RigidBody, .{
        .radius = self.kevin_radius,
        .density = std.math.inf(f32),
    });
    thruster.add(cb, AnimateOnInput, .{
        .action = .thrust_forward,
        .direction = .positive,
        .activated = self.kevin_animations.accel,
        .deactivated = .none,
    });
    thruster.add(cb, Animation.Playback, .{ .index = .none });
    thruster.add(cb, PlayerIndex, player_index);
}

fn createWendy(
    self: *const @This(),
    cb: *CmdBuf,
    player_index: PlayerIndex,
    team_index: TeamIndex,
    pos: Vec2,
    _: f32,
) void {
    const ship = Entity.reserve(cb);
    ship.add(cb, Ship, .{
        .class = .wendy,
        .turn_speed = math.pi * 1.0,
        .thrust = 200,
        .omnithrusters = true,
    });
    ship.add(cb, Health, .{
        .hp = 400,
        .max_hp = 400,
    });
    ship.add(cb, Transform, .{
        .pos = pos,
    });
    ship.add(cb, RigidBody, .{
        .vel = .zero,
        .radius = self.wendy_radius,
        .rotation_vel = 0.0,
        .density = 0.02,
    });
    ship.add(cb, Collider, .{
        .collision_damping = 0.4,
        .layer = .vehicle,
    });
    ship.add(cb, Animation.Playback, .{
        .index = self.wendy_animations.still,
    });
    ship.add(cb, PlayerIndex, player_index);
    ship.add(cb, TeamIndex, team_index);
    ship.add(cb, Turret, .{
        .radius = self.wendy_radius,
        .cooldown = .{ .distance = .{ .min_sq = std.math.pow(f32, 10.0, 2.0) } },
        .projectile_speed = 0,
        .projectile_lifetime = 5.0,
        .projectile_damage = 50,
        .projectile_radius = 8,
        .projectile_density = std.math.inf(f32),
        .aim_opposite_movement = true,
    });

    {
        const thruster = Entity.reserve(cb);
        cb.ext(Node.SetParent, .{ .child = thruster, .parent = ship.toOptional() });
        thruster.add(cb, Transform, .{});
        thruster.add(cb, RigidBody, .{
            .radius = self.wendy_radius,
            .density = std.math.inf(f32),
        });
        thruster.add(cb, AnimateOnInput, .{
            .action = .thrust_y,
            .direction = .positive,
            .activated = self.wendy_animations.thrusters_bottom.?,
            .deactivated = .none,
        });
        thruster.add(cb, Animation.Playback, .{ .index = .none });
        thruster.add(cb, PlayerIndex, player_index);
    }

    {
        const thruster = Entity.reserve(cb);
        cb.ext(Node.SetParent, .{ .child = thruster, .parent = ship.toOptional() });
        thruster.add(cb, Transform, .{});
        thruster.add(cb, RigidBody, .{
            .radius = self.wendy_radius,
            .density = std.math.inf(f32),
        });
        thruster.add(cb, AnimateOnInput, .{
            .action = .thrust_y,
            .direction = .negative,
            .activated = self.wendy_animations.thrusters_top.?,
            .deactivated = .none,
        });
        thruster.add(cb, Animation.Playback, .{ .index = .none });
        thruster.add(cb, PlayerIndex, player_index);
    }

    {
        const thruster = Entity.reserve(cb);
        cb.ext(Node.SetParent, .{ .child = thruster, .parent = ship.toOptional() });
        thruster.add(cb, Transform, .{});
        thruster.add(cb, RigidBody, .{
            .radius = self.wendy_radius,
            .density = std.math.inf(f32),
        });
        thruster.add(cb, AnimateOnInput, .{
            .action = .thrust_x,
            .direction = .negative,
            .activated = self.wendy_animations.thrusters_right.?,
            .deactivated = .none,
        });
        thruster.add(cb, Animation.Playback, .{ .index = .none });
        thruster.add(cb, PlayerIndex, player_index);
    }

    {
        const thruster = Entity.reserve(cb);
        cb.ext(Node.SetParent, .{ .child = thruster, .parent = ship.toOptional() });
        thruster.add(cb, Transform, .{});
        thruster.add(cb, RigidBody, .{
            .radius = self.wendy_radius,
            .density = std.math.inf(f32),
        });
        thruster.add(cb, AnimateOnInput, .{
            .action = .thrust_x,
            .direction = .positive,
            .activated = self.wendy_animations.thrusters_left.?,
            .deactivated = .none,
        });
        thruster.add(cb, Animation.Playback, .{ .index = .none });
        thruster.add(cb, PlayerIndex, player_index);
    }
}

pub fn init(
    gpa: Allocator,
    rng: Random,
    es: *Entities,
    assets: *Assets,
    renderer: *Renderer,
    gx: *Gx,
    window_extent: gpu.Extent2D,
) !Game {
    const init_zone = Zone.begin(.{ .src = @src() });
    defer init_zone.end();

    renderer.beginFrame(gx);
    var cb: gpu.CmdBuf = .init(gx, .{
        .name = "Color Image Upload",
        .src = @src(),
    });
    const image_staging: gpu.UploadBuf(.{ .transfer_src = true }) = .init(gx, .{
        .name = .{ .str = "Upload Queue" },
        .size = Renderer.image_mibs * Renderer.mib,
        .prefer_device_local = false,
    });
    var up: ImageUploadQueue = .init(image_staging.view());
    renderer.delete_queues[gx.frame].append(image_staging);

    // On most of the platforms we care about we could just use `selfExeDirPathAlloc`, but the SDL
    // call works under wine
    const path = try std.fs.path.join(gpa, &.{ std.mem.span(c.SDL_GetBasePath()), "data" });
    defer gpa.free(path);
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();

    const ring_bg = assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ring.png", null);
    const star_small = assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/star/small.png", null);
    const star_large = assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/star/large.png", null);
    const planet_red = assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/planet-red.png", null);
    const bullet_small = assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/bullet/small.png", null);
    const bullet_shiny = assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/bullet/shiny.png", null);

    var shrapnel_sprites: [shrapnel_sprite_names.len]Sprite.Index = undefined;
    for (&shrapnel_sprites, shrapnel_sprite_names) |*s, name| {
        s.* = assets.loadSprite(gpa, gx, renderer, cb, &up, dir, name, null);
    }

    var rock_sprites: [rock_sprite_names.len]Sprite.Index = undefined;
    for (&rock_sprites, rock_sprite_names) |*s, name| {
        s.* = assets.loadSprite(gpa, gx, renderer, cb, &up, dir, name, null);
    }

    const shrapnel_animations: [shrapnel_sprites.len]Animation.Index = .{
        try assets.addAnimation(gpa, &.{shrapnel_sprites[0]}, null, 30, 0.0),
        try assets.addAnimation(gpa, &.{shrapnel_sprites[1]}, null, 30, 0.0),
        try assets.addAnimation(gpa, &.{shrapnel_sprites[2]}, null, 30, 0.0),
    };

    const ranger_sprites = .{
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/ranger/diffuse.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/ranger/thrusters/0.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/ranger/thrusters/1.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/ranger/thrusters/2.png", null),
    };
    const ranger_still = try assets.addAnimation(gpa, &.{
        ranger_sprites[0],
    }, null, 30, 0.0);
    const ranger_steady_thrust = try assets.addAnimation(gpa, &.{
        ranger_sprites[2],
        ranger_sprites[3],
    }, null, 10, 0.0);
    const ranger_accel = try assets.addAnimation(gpa, &.{
        ranger_sprites[1],
    }, ranger_steady_thrust, 10, 0.0);

    const militia_sprites = .{
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/militia/diffuse.png", "img/ship/militia/recolor.png"),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/militia/thrusters/0.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/militia/thrusters/1.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/militia/thrusters/2.png", null),
    };
    const militia_still = try assets.addAnimation(gpa, &.{
        militia_sprites[0],
    }, null, 30, 0.0);
    const militia_steady_thrust = try assets.addAnimation(gpa, &.{
        militia_sprites[2],
        militia_sprites[3],
    }, null, 10, 0.0);
    const militia_accel = try assets.addAnimation(gpa, &.{
        militia_sprites[1],
    }, militia_steady_thrust, 10, 0.0);

    const explosion_animation = try assets.addAnimation(gpa, &.{
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/01.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/02.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/03.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/04.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/05.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/06.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/07.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/08.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/09.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/10.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/11.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/explosion/12.png", null),
    }, .none, 30, 0.0);

    const triangle_sprites = .{
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/triangle/diffuse.png", "img/ship/triangle/recolor.png"),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/triangle/thrusters/0.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/triangle/thrusters/1.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/triangle/thrusters/2.png", null),
    };
    const triangle_still = try assets.addAnimation(gpa, &.{
        triangle_sprites[0],
    }, null, 30, 0.0);
    const triangle_steady_thrust = try assets.addAnimation(gpa, &.{
        triangle_sprites[2],
        triangle_sprites[3],
    }, null, 10, 0.0);
    const triangle_accel = try assets.addAnimation(gpa, &.{
        triangle_sprites[1],
    }, triangle_steady_thrust, 10, 0.0);

    const kevin_sprites = .{
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/kevin/diffuse.png", "img/ship/kevin/recolor.png"),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/kevin/thrusters/0.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/kevin/thrusters/1.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/kevin/thrusters/2.png", null),
    };
    const kevin_still = try assets.addAnimation(gpa, &.{
        kevin_sprites[0],
    }, null, 30, 0.0);
    const kevin_steady_thrust = try assets.addAnimation(gpa, &.{
        kevin_sprites[2],
        kevin_sprites[3],
    }, null, 10, 0.0);
    const kevin_accel = try assets.addAnimation(gpa, &.{
        kevin_sprites[1],
    }, kevin_steady_thrust, 10, 0.0);

    const wendy_sprite = assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/diffuse.png", "img/ship/wendy/recolor.png");
    const wendy_thrusters_left = .{
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/left/0.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/left/1.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/left/2.png", null),
    };
    const wendy_thrusters_right = .{
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/right/0.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/right/1.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/right/2.png", null),
    };
    const wendy_thrusters_top = .{
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/top/0.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/top/1.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/top/2.png", null),
    };
    const wendy_thrusters_bottom = .{
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/bottom/0.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/bottom/1.png", null),
        assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/ship/wendy/thrusters/bottom/2.png", null),
    };
    const wendy_still = try assets.addAnimation(gpa, &.{
        wendy_sprite,
    }, null, 30, 0.0);
    const wendy_thrusters_left_steady = try assets.addAnimation(gpa, &.{
        wendy_thrusters_left[1],
        wendy_thrusters_left[2],
    }, null, 10, 0.0);
    const wendy_thrusters_left_accel = try assets.addAnimation(gpa, &.{
        wendy_thrusters_left[0],
    }, wendy_thrusters_left_steady, 10, 0.0);
    const wendy_thrusters_right_steady = try assets.addAnimation(gpa, &.{
        wendy_thrusters_right[1],
        wendy_thrusters_right[2],
    }, null, 10, 0.0);
    const wendy_thrusters_right_accel = try assets.addAnimation(gpa, &.{
        wendy_thrusters_right[0],
    }, wendy_thrusters_right_steady, 10, 0.0);
    const wendy_thrusters_top_steady = try assets.addAnimation(gpa, &.{
        wendy_thrusters_top[1],
        wendy_thrusters_top[2],
    }, null, 10, 0.0);
    const wendy_thrusters_top_accel = try assets.addAnimation(gpa, &.{
        wendy_thrusters_top[0],
    }, wendy_thrusters_top_steady, 10, 0.0);
    const wendy_thrusters_bottom_steady = try assets.addAnimation(gpa, &.{
        wendy_thrusters_bottom[1],
        wendy_thrusters_bottom[2],
    }, null, 10, 0.0);
    const wendy_thrusters_bottom_accel = try assets.addAnimation(gpa, &.{
        wendy_thrusters_bottom[0],
    }, wendy_thrusters_bottom_steady, 10, 0.0);

    const ranger_radius = assets.sprite(ranger_sprites[0]).radius();
    const militia_radius = assets.sprite(militia_sprites[0]).radius();
    const triangle_radius = assets.sprite(triangle_sprites[0]).radius();
    const kevin_radius = assets.sprite(triangle_sprites[0]).radius();
    const wendy_radius = assets.sprite(triangle_sprites[0]).radius();

    const particle = assets.loadSprite(gpa, gx, renderer, cb, &up, dir, "img/particle.png", null);

    const controller_default = input_system.ControlScheme.Controller{
        .turn = .{
            .axis = .{
                .axis = c.SDL_GAMEPAD_AXIS_LEFTX,
                .dead_zone = dead_zone,
            },
        },
        .thrust_forward = .{
            .buttons = .{ .positive = c.SDL_GAMEPAD_BUTTON_EAST },
            .axis = .{
                .axis = c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER,
                .dead_zone = dead_zone,
            },
        },
        .thrust_x = .{
            .axis = .{
                .axis = c.SDL_GAMEPAD_AXIS_LEFTX,
                .dead_zone = dead_zone,
            },
        },
        .thrust_y = .{
            .axis = .{
                .axis = c.SDL_GAMEPAD_AXIS_LEFTY,
                .dead_zone = dead_zone,
            },
        },
        .fire = .{
            .buttons = .{ .positive = c.SDL_GAMEPAD_BUTTON_SOUTH },
            .axis = .{
                .axis = c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
                .dead_zone = dead_zone,
            },
        },
        .start = .{
            .buttons = .{ .positive = c.SDL_GAMEPAD_BUTTON_START },
        },
    };
    const keyboard_wasd = input_system.ControlScheme.Keyboard{
        .turn = .{
            .positive = c.SDL_SCANCODE_D,
            .negative = c.SDL_SCANCODE_A,
        },
        .thrust_forward = .{ .positive = c.SDL_SCANCODE_W },
        .thrust_x = .{
            .positive = c.SDL_SCANCODE_D,
            .negative = c.SDL_SCANCODE_A,
        },
        .thrust_y = .{
            .positive = c.SDL_SCANCODE_W,
            .negative = c.SDL_SCANCODE_S,
        },
        .fire = .{
            .positive = c.SDL_SCANCODE_LSHIFT,
        },
        .start = .{
            .positive = c.SDL_SCANCODE_TAB,
        },
    };
    const keyboard_arrows = input_system.ControlScheme.Keyboard{
        .turn = .{
            .positive = c.SDL_SCANCODE_RIGHT,
            .negative = c.SDL_SCANCODE_LEFT,
        },
        .thrust_forward = .{
            .positive = c.SDL_SCANCODE_UP,
        },
        .thrust_x = .{
            .positive = c.SDL_SCANCODE_RIGHT,
            .negative = c.SDL_SCANCODE_LEFT,
        },
        .thrust_y = .{
            .positive = c.SDL_SCANCODE_UP,
            .negative = c.SDL_SCANCODE_DOWN,
        },
        .fire = .{
            .positive = c.SDL_SCANCODE_RSHIFT,
        },
        .start = .{
            .positive = c.SDL_SCANCODE_RETURN,
        },
    };
    const keyboard_none: input_system.ControlScheme.Keyboard = .{
        .turn = .{},
        .thrust_forward = .{},
        .thrust_x = .{},
        .thrust_y = .{},
        .fire = .{},
        .start = .{},
    };

    const zone: Zone = .begin(.{ .name = "Upload Images", .src = @src() });
    defer zone.end();

    var image_barriers = std.ArrayListUnmanaged(gpu.ImageBarrier).initCapacity(gpa, Renderer.max_textures) catch @panic("OOM");
    defer image_barriers.deinit(gpa);
    for (renderer.textures.items) |texture| {
        image_barriers.appendAssumeCapacity(.{
            .image = texture.handle,
            .range = .first(.{ .color = true }),
            .src = .{
                .stages = .{ .copy = true },
                .access = .{ .transfer_write = true },
                .layout = .transfer_dst,
            },
            .dst = .{
                .stages = .{ .fragment = true },
                .access = .{ .shader_read = true },
                .layout = .read_only,
            },
        });
    }
    cb.barriers(gx, .{ .image = image_barriers.items });

    cb.end(gx);
    gx.submit(&.{cb});
    _ = gx.endFrame(.{ .present = null });

    const color_buffer = renderer.rtp.alloc(gx, .{
        .name = .{ .str = "Color Buffer" },
        .image = .{
            .format = Renderer.Pipelines.color_attachment_format,
            .extent = .{
                .width = 1920,
                .height = 1080,
                .depth = 1,
            },
            .usage = .{
                .color_attachment = true,
                .storage = true,
                .sampled = true,
                .transfer_src = true,
            },
        },
    });

    const composite = renderer.rtp.alloc(gx, .{
        .name = .{ .str = "Composite" },
        .image = .{
            .format = switch (@as(Renderer.Surface, @enumFromInt(gx.device.surface_format.userdata))) {
                .nonlinear_srgb, .linear_srgb => Renderer.Pipelines.color_attachment_format,
                .hdr10 => .a2b10g10r10_unorm,
                .linear_srgb_extended, .nonlinear_srgb_extended => .r16g16b16a16_sfloat,
            },
            .extent = .{
                .width = 1920,
                .height = 1080,
                .depth = 1,
            },
            .usage = .{
                .storage = true,
                .transfer_src = true,
            },
        },
    });

    var blurred: [2]RenderTarget(.color) = undefined;
    for (&blurred, 0..) |*rt, i| {
        rt.* = renderer.rtp.alloc(gx, .{
            .name = .{ .str = "Blurred", .index = i },
            .image = .{
                .format = Renderer.Pipelines.color_attachment_format,
                .extent = .{
                    .width = 1920 / 4,
                    .height = 1080 / 4,
                    .depth = 1,
                },
                .usage = .{
                    .storage = true,
                    .sampled = true,
                    .transfer_dst = i == 1,
                },
            },
        });
    }

    var desc_set_updates: std.ArrayList(gpu.DescSet.Update) = try .initCapacity(gpa, 128);
    defer desc_set_updates.deinit();

    for (renderer.desc_sets, 0..) |set, frame| {
        if (desc_set_updates.items.len >= desc_set_updates.capacity) @panic("OOB");
        try desc_set_updates.append(.{
            .set = set,
            .binding = Renderer.pipeline_layout_options.binding("scene"),
            .value = .{
                .storage_buf = renderer.scene[frame].asBuf(.{ .storage = true }),
            },
        });
        if (desc_set_updates.items.len >= desc_set_updates.capacity) @panic("OOB");
        try desc_set_updates.append(.{
            .set = set,
            .binding = Renderer.pipeline_layout_options.binding("entities"),
            .value = .{
                .storage_buf = renderer.entities[frame].asBuf(.{ .storage = true }),
            },
        });
        try desc_set_updates.append(.{
            .set = set,
            .binding = Renderer.pipeline_layout_options.binding("entities_len"),
            .value = .{
                .storage_buf = renderer.entities_len[frame].asBuf(.{ .storage = true }),
            },
        });

        for (renderer.textures.items, 0..) |texture, texture_index| {
            if (texture_index > Renderer.max_textures) @panic("textures oob");
            try desc_set_updates.append(.{
                .set = set,
                .binding = Renderer.pipeline_layout_options.binding("textures"),
                .index = @intCast(texture_index),
                .value = .{ .sampled_image = texture.view },
            });
        }
    }
    gx.updateDescSets(desc_set_updates.items);

    return .{
        .gx = gx,
        .es = es,
        .debug_allocator = gpa,
        .renderer = renderer,
        .assets = assets,
        .teams = undefined,
        .teams_buffer = undefined,
        .shrapnel_animations = shrapnel_animations,
        .explosion_animation = explosion_animation,
        .control_schemes = .{
            .{
                .controller_index = 0,
                .controller_scheme = controller_default,
                .keyboard_scheme = keyboard_wasd,
            },
            .{
                .controller_index = 1,
                .controller_scheme = controller_default,
                .keyboard_scheme = keyboard_arrows,
            },
            .{
                .controller_index = 2,
                .controller_scheme = controller_default,
                .keyboard_scheme = keyboard_none,
            },
            .{
                .controller_index = 3,
                .controller_scheme = controller_default,
                .keyboard_scheme = keyboard_none,
            },
        },
        .input_state = .{input_system.InputState.init()} ** 4,
        .rng = rng,

        .ring_bg = ring_bg,
        .star_small = star_small,
        .star_large = star_large,
        .planet_red = planet_red,
        .bullet_small = bullet_small,
        .bullet_shiny = bullet_shiny,
        .rock_sprites = rock_sprites,

        .ranger_animations = .{
            .still = ranger_still,
            .accel = ranger_accel,
        },
        .ranger_radius = ranger_radius,

        .militia_animations = .{
            .still = militia_still,
            .accel = militia_accel,
        },
        .militia_radius = militia_radius,

        .triangle_animations = .{
            .still = triangle_still,
            .accel = triangle_accel,
        },
        .triangle_radius = triangle_radius,

        .kevin_animations = .{
            .still = kevin_still,
            .accel = kevin_accel,
        },
        .kevin_radius = kevin_radius,

        .wendy_animations = .{
            .still = wendy_still,
            .accel = wendy_still,
            .thrusters_left = wendy_thrusters_left_accel,
            .thrusters_right = wendy_thrusters_right_accel,
            .thrusters_top = wendy_thrusters_top_accel,
            .thrusters_bottom = wendy_thrusters_bottom_accel,
        },
        .wendy_radius = wendy_radius,

        .stars = undefined,

        .particle = particle,

        .color_buffer = color_buffer,
        .composite = composite,
        .blurred = blurred,
        .window_extent = window_extent,
        .resize_timer = std.time.Timer.start() catch |err| @panic(@errorName(err)),
    };
}

pub fn createShip(
    game: *Game,
    cb: *CmdBuf,
    player_index: PlayerIndex,
    team_index: TeamIndex,
    pos: Vec2,
    angle: f32,
) void {
    const team = &game.teams[@intFromEnum(team_index)];
    const progression_index = team.ship_progression_index;
    team.ship_progression_index += 1;
    switch (team.ship_progression[progression_index]) {
        .ranger => game.createRanger(cb, player_index, team_index, pos, angle),
        .militia => game.createMilitia(cb, player_index, team_index, pos, angle),
        .triangle => game.createTriangle(cb, player_index, team_index, pos, angle),
        .kevin => game.createKevin(cb, player_index, team_index, pos, angle),
        .wendy => game.createWendy(cb, player_index, team_index, pos, angle),
    }
}

pub fn shipLifeSprite(game: Game, class: Ship.Class) Sprite.Index {
    const animation_index = switch (class) {
        .ranger => game.ranger_animations.still,
        .militia => game.militia_animations.still,
        .triangle => game.triangle_animations.still,
        .kevin => game.kevin_animations.still,
        .wendy => game.wendy_animations.still,
    };
    const animation = game.assets.animations.items[@intFromEnum(animation_index)];
    const sprite_index = game.assets.frames.items[animation.start];
    return sprite_index;
}

pub fn animationRadius(game: Game, animation_index: Animation.Index) f32 {
    const assets = game.assets;
    const animation = assets.animations.items[@intFromEnum(animation_index)];
    const sprite_index = assets.frames.items[animation.start];
    const sprite = assets.sprites.items[@intFromEnum(sprite_index)];
    return sprite.radius();
}

const Scenario = enum {
    deathmatch_2v2,
    deathmatch_2v2_no_rocks,
    deathmatch_2v2_one_rock,
    deathmatch_1v1,
    deathmatch_1v1_one_rock,
    royale_4p,
};

pub fn setupScenario(game: *Game, es: *Entities, cb: *CmdBuf, scenario: Scenario) void {
    cb.clear(es);
    es.destroyArchImmediate(.initEmpty());

    var player_teams: []const u2 = undefined;

    switch (scenario) {
        .deathmatch_2v2,
        .deathmatch_2v2_no_rocks,
        .deathmatch_2v2_one_rock,
        => {
            const progression = &.{
                .ranger,
                .militia,
                .ranger,
                .militia,
                .triangle,
                .triangle,
                .wendy,
                .kevin,
            };
            const team_init: Team = .{
                .ship_progression_index = 0,
                .ship_progression = progression,
                .players_alive = 2,
            };
            const teams = game.teams_buffer[0..2];
            teams.* = .{ team_init, team_init };
            game.teams = teams;

            player_teams = &.{ 0, 1, 0, 1 };
        },

        .deathmatch_1v1, .deathmatch_1v1_one_rock => {
            const progression = &.{
                .ranger,
                .militia,
                .triangle,
                .wendy,
                .kevin,
            };
            const team_init: Team = .{
                .ship_progression_index = 0,
                .ship_progression = progression,
                .players_alive = 1,
            };
            const teams = game.teams_buffer[0..2];
            teams.* = .{ team_init, team_init };
            game.teams = teams;

            player_teams = &.{ 0, 1 };
        },

        .royale_4p => {
            const progression = &.{
                .ranger,
                .militia,
                .triangle,
                .wendy,
                .kevin,
            };
            const team_init: Team = .{
                .ship_progression_index = 0,
                .ship_progression = progression,
                .players_alive = 1,
            };
            const teams = game.teams_buffer[0..4];
            teams.* = .{ team_init, team_init, team_init, team_init };
            game.teams = teams;

            player_teams = &.{ 0, 1, 2, 3 };
        },
    }

    // Set up players
    {
        b: {
            var player_index: u32 = 0;
            var gamepads_len: c_int = 0;
            const gamepads = c.SDL_GetGamepads(&gamepads_len) orelse {
                log.err("SDL_GetGamepads failed: {s}", .{c.SDL_GetError()});
                break :b;
            };
            defer c.SDL_free(gamepads);
            for (gamepads[0..@intCast(gamepads_len)]) |id| {
                const gamepad = c.SDL_OpenGamepad(id) orelse {
                    log.err("SDL_GamepadOpen({}) failed: {s}\n", .{ id, c.SDL_GetError() });
                    continue;
                };
                game.controllers[player_index] = gamepad;
                log.info("Player 1: {s}", .{c.SDL_GetGamepadName(gamepad) orelse "null".ptr});
                player_index += 1;
                if (player_index >= game.controllers.len) break;
            }
        }

        for (player_teams, 0..) |team_index, i| {
            const angle = math.pi / 2.0 * @as(f32, @floatFromInt(i));
            const pos = display_center.plus(Vec2.unit(angle).scaled(50));
            const player_index: PlayerIndex = @enumFromInt(i);
            game.createShip(cb, player_index, @enumFromInt(team_index), pos, math.pi / 2.0 - angle);
        }
    }

    // Create rocks
    const rock_amt: usize = switch (scenario) {
        .deathmatch_2v2_no_rocks => 0,
        .deathmatch_2v2_one_rock => 1,
        .deathmatch_2v2 => 3,
        .deathmatch_1v1 => 3,
        .deathmatch_1v1_one_rock => 1,
        .royale_4p => 1,
    };
    // TODO: random in circle biased doesn't need to be scaled, audit other calls to this
    for (0..rock_amt) |_| {
        const speed = 20 + game.rng.float(f32) * 300;
        const radius = 25 + game.rng.float(f32) * 110;
        const sprite = game.rock_sprites[game.rng.uintLessThanBiased(usize, game.rock_sprites.len)];
        const pos = randomInCircleBiased(game.rng, lerp(display_radius, display_radius * 1.1, game.rng.float(f32)))
            .plus(display_center);

        const e = Entity.reserve(cb);
        e.add(cb, Sprite.Index, sprite);
        e.add(cb, Transform, .{
            .pos = pos,
        });
        e.add(cb, RigidBody, .{
            .vel = randomOnCircle(game.rng, speed),
            .rotation_vel = lerp(-1.0, 1.0, game.rng.float(f32)),
            .radius = radius,
            .density = 0.10,
        });
        e.add(cb, Collider, .{
            .collision_damping = 1,
            .layer = .hazard,
        });
    }

    // Create stars
    generateStars(&game.stars, game.rng);
}

pub fn spawnTeamVictory(game: *Game, cb: *CmdBuf, pos: Vec2, team_index: TeamIndex) void {
    for (0..500) |_| {
        const random_vel = randomOnCircle(game.rng, 300);
        const e = Entity.reserve(cb);
        e.add(cb, Lifetime, .{
            .seconds = 1000,
        });
        e.add(cb, Transform, .{
            .pos = pos,
            .rot = .fromAngle(math.tau * game.rng.float(f32)),
        });
        e.add(cb, RigidBody, .{
            .vel = random_vel,
            .rotation_vel = math.tau * game.rng.float(f32),
            .radius = 16,
            .density = 0.001,
        });
        e.add(cb, Sprite.Index, game.particle);
        e.add(cb, TeamIndex, team_index);
    }
}

pub fn aliveTeam(game: Game) TeamIndex {
    for (game.teams, 0..) |team, i| {
        if (team.players_alive > 0) return @enumFromInt(i);
    } else unreachable;
}

fn aliveTeamCount(game: Game) u32 {
    var count: u32 = 0;
    for (game.teams) |team| {
        count += @intFromBool(team.players_alive > 0);
    }
    return count;
}

pub fn over(game: Game) bool {
    return game.aliveTeamCount() <= 1;
}

fn generateStars(stars: []Star, random: std.Random) void {
    const margin = @max(display_size.x, display_size.y);
    for (stars) |*star| {
        star.* = .{
            .pos = .{
                .x = lerp(-margin, margin * 2, random.float(f32)),
                .y = lerp(-margin, margin * 2, random.float(f32)),
            },
            .kind = @enumFromInt(random.uintLessThanBiased(u8, 2)),
        };
    }
    // Draw some planets on top of the stars
    for (0..10) |i| {
        stars[stars.len - i - 1].kind = .planet_red;
    }
}

pub fn clearInvulnerability(es: *Entities) void {
    // Clear invulnerability so you don't have to wait when testing
    var it = es.iterator(struct { health: *Health });
    while (it.next(es)) |vw| {
        vw.health.invulnerable_s = 0.0;
    }
}

pub fn randomOnCircle(random: std.Random, radius: f32) Vec2 {
    return Vec2.unit(random.float(f32) * math.tau).scaled(radius);
}

pub fn randomInCircleBiased(random: std.Random, radius: f32) Vec2 {
    return randomOnCircle(random, radius * random.float(f32));
}

pub const input_system = @import("input_system.zig").init(enum {
    turn,
    thrust_forward,
    thrust_x,
    thrust_y,
    fire,
    start,
});

pub const Star = struct {
    pos: Vec2,
    kind: Kind,

    const Kind = enum { large, small, planet_red };
};

pub const Team = struct {
    ship_progression_index: u32,
    ship_progression: []const Ship.Class,
    players_alive: u2,
};

pub const PlayerIndex = enum(u2) { _ };

pub const Damage = struct {
    hp: f32,
};

/// A spring connecting two entities.
///
/// You can simulate a rod by choosing a high spring constant and setting the damping factor to 1.0.
pub const Spring = struct {
    start: Entity,
    end: Entity,

    /// 0.0 is no damping, 1.0 is critical damping (no bouncing), greater than 1.0 is overdamped.
    damping: f32,
    /// The spring constant. The higher it is, the stronger the spring. Very high will make it
    /// rod-like, but setting it too high can cause numerical instability, with the instability
    /// getting worse the lower the framerate.
    k: f32,
    /// The length of the spring.
    length: f32,
};

pub const Hook = struct {
    damping: f32,
    k: f32,
};

pub const FrontShield = struct {};

pub const Lifetime = struct {
    seconds: f32,
};

pub const Cooldown = union(enum) {
    time: struct {
        max_s: f32,
        current_s: f32 = 0.0,
    },
    distance: struct {
        min_sq: f32,
        last_pos: ?Vec2 = null,
    },
};

pub const Turret = struct {
    radius: f32,
    cooldown: Cooldown,

    aim_opposite_movement: bool = false,

    /// pixels per second
    projectile_speed: f32,
    /// seconds
    projectile_lifetime: f32,
    /// Amount of HP the projectile removes upon landing a hit.
    projectile_damage: f32,
    /// Radius of spawned projectiles.
    projectile_radius: f32,
    projectile_density: f32 = 0.001,
};

pub const GrappleGun = struct {
    const segments = 10;

    /// Together with angle, this is the location of the gun from the center
    /// of the containing object. Pixels.
    radius: f32,
    /// Together with radius, this is the location of the gun from the
    /// center of the containing object. Radians.
    angle: f32,
    /// Seconds until ready. Less than or equal to 0 means ready.
    cooldown_s: f32,
    /// Seconds until ready. Cooldown is set to this after firing.
    max_cooldown_s: f32,

    /// pixels per second
    projectile_speed: f32,
    // TODO: ...
    // /// seconds
    // projectile_lifetime: f32,

    // TODO: if we add this back, need to make it not destroy itself on damage
    // /// Amount of HP the projectile removes upon landing a hit.
    // projectile_damage: f32,

    /// The live chain of projectiles.
    live: ?struct {
        springs: [segments]Entity,
        joints: [segments - 1]Entity,
        hook: Entity,
    } = null,
};

pub const AnimateOnInput = struct {
    action: input_system.Action,
    direction: input_system.Direction,
    activated: Animation.Index,
    deactivated: Animation.Index,
};

pub const RigidBody = struct {
    pub fn mass(self: RigidBody) f32 {
        return self.density * math.pi * self.radius * self.radius;
    }

    /// pixels per second
    vel: Vec2 = .zero,
    /// radians per second
    rotation_vel: f32 = 0.0,
    radius: f32,
    // TODO(mason): why density and not inverse mass? probably a good reason i just wanna understand
    // gotta look at how it's used.
    density: f32,
};

pub const Collider = struct {
    const Layer = enum {
        vehicle,
        hazard,
        projectile,
        hook,
    };
    pub const interacts: SymmetricMatrix(Layer, bool) = interacts: {
        var m = SymmetricMatrix(Layer, bool).init(true);
        m.set(.projectile, .projectile, false);
        m.set(.vehicle, .projectile, false);
        // TODO: why doesn't this cause an issue if not set?
        m.set(.projectile, .hook, false);
        break :interacts m;
    };

    collision_damping: f32,
    layer: Layer,
};

pub const Health = struct {
    pub const max_invulnerable_s: f32 = 4.0;

    hp: f32,
    max_hp: f32,
    max_regen_cooldown_s: f32 = 1.5,
    regen_cooldown_s: f32 = 0.0,
    regen_ratio: f32 = 1.0 / 3.0,
    regen_s: f32 = 2.0,
    invulnerable_s: f32 = max_invulnerable_s,

    pub fn damage(
        self: *@This(),
        game: *Game,
        amount: f32,
        source_opt: Entity.Optional,
    ) f32 {
        if (self.invulnerable_s <= 0.0) {
            const trauma_intensity = remap(0.0, self.hp, 0.4, 0.7, amount);
            if (game.es.getComp(self, PlayerIndex)) |pi| {
                game.player_trauma[@intFromEnum(pi.*)].set(.low, trauma_intensity);
            }
            if (source_opt.unwrap()) |source| {
                if (source.get(game.es, PlayerIndex)) |pi| {
                    game.player_trauma[@intFromEnum(pi.*)].set(.high, trauma_intensity);
                }
            }
            self.hp -= amount;
            self.regen_cooldown_s = self.max_regen_cooldown_s;
            return amount;
        } else {
            return 0;
        }
    }
};

pub const Ship = struct {
    /// radians per second
    turn_speed: f32,
    /// pixels per second squared
    thrust: f32,
    omnithrusters: bool = false,

    class: Class,

    pub const Class = enum {
        ranger,
        militia,
        triangle,
        kevin,
        wendy,
    };
};

pub const TeamIndex = enum(u2) { _ };
