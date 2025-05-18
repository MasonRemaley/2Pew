const std = @import("std");
const c = @import("c.zig");
const panic = std.debug.panic;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const math = std.math;
const assert = std.debug.assert;
const zcs = @import("zcs");
const typeId = zcs.typeId;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Component = zcs.Component;
const CmdBuf = zcs.CmdBuf;
const Node = zcs.ext.Node;
const Vec2 = zcs.ext.geom.Vec2;
const Rotor2 = zcs.ext.geom.Rotor2;
const Mat2x3 = zcs.ext.geom.Mat2x3;
const Transform = zcs.ext.Transform2D;
const FieldEnum = std.meta.FieldEnum;
const SymmetricMatrix = @import("symmetric_matrix.zig").SymmetricMatrix;
const gpu = @import("gpu");
const VkBackend = @import("VkBackend");
const Gx = gpu.Gx;
const build = @import("build.zig.zon");
const logger = @import("logger");
const Logger = logger.Logger(.{ .history = .none });
const structopt = @import("structopt");
const Command = structopt.Command;
const NamedArg = structopt.NamedArg;
const log = std.log.scoped(build.name);
const ImageUploadQueue = @import("ImageUploadQueue.zig");
const BufferLayout = @import("buffer_layout.zig").BufferLayout;

const tracy = @import("tracy");
const Zone = tracy.Zone;

pub const tracy_impl = @import("tracy_impl");

pub const std_options: std.Options = .{
    .logFn = Logger.logFn,
    .log_level = .info,
};

const command: Command = .{
    .name = @tagName(build.name),
    .named_args = &.{
        NamedArg.init(Gx.Options.DebugMode, .{
            .long = "gpu-debug",
            .default = .{ .value = if (builtin.mode == .Debug) .validate else .none },
        }),
        NamedArg.init(bool, .{
            .long = "gx",
            .default = .{ .value = false },
        }),
    },
};

const tween = zcs.ext.geom.tween;

const lerp = tween.interp.lerp;
const remap = tween.interp.remap;
const remapClamped = tween.interp.remapClamped;

const input_system = @import("input_system.zig").init(enum {
    turn,
    thrust_forward,
    thrust_x,
    thrust_y,
    fire,
    start,
});

const display_width = 1920;
const display_height = 1080;
const display_center: Vec2 = .{
    .x = display_width / 2.0,
    .y = display_height / 2.0,
};
const display_radius = display_height / 2.0;

const PrefabEntity = Entities.PrefabEntity;
const ComponentFlags = Entities.ComponentFlags;

const dead_zone = 10000;

// This turns off vsync and logs the frame times to the console. Even better would be debug text on
// screen including this, the number of live entities, etc. We also want warnings/errors to show up
// on screen so we see them immediately when they happen (as well as being logged to the console and
// to a file.)
const profile = false;

pub const gpu_options: gpu.Options = .{
    .Backend = VkBackend,
};

pub const VkRenderer = struct {
    gx: Gx,
    upload_queue: ImageUploadQueue,
    color_images: gpu.Memory(.color_image),
    upload_offset: u64 = 0,

    fn deinit(self: *@This(), gpa: Allocator) void {
        self.upload_queue.deinit(&self.gx);
        self.color_images.deinit(&self.gx);
        self.gx.deinit(gpa);
        self.* = undefined;
    }
};

const Renderer = union(enum) {
    sdl: *c.SDL_Renderer,
    vk: VkRenderer,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    var tracy_allocator: tracy.Allocator = .{
        .pool_name = "gpa",
        .parent = gpa.allocator(),
    };
    const allocator = tracy_allocator.allocator();

    const args = try command.parse(allocator);
    defer command.parseFree(args);

    // Init SDL
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
        .Debug => c.SDL_WINDOW_RESIZABLE,
        else => c.SDL_WINDOW_FULLSCREEN,
    };

    const screen = c.SDL_CreateWindow(
        @tagName(build.name),
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        display_width,
        display_height,
        window_mode | c.SDL_WINDOW_VULKAN,
    ) orelse {
        panic("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyWindow(screen);

    var renderer: Renderer = if (args.named.gx) b: {
        const app_version = comptime std.SemanticVersion.parse(build.version) catch unreachable;
        var instance_ext_count: u32 = 0;
        if (c.SDL_Vulkan_GetInstanceExtensions(screen, &instance_ext_count, null) != c.SDL_TRUE) {
            return error.SdlVkGetInstanceExtensionsError;
        }
        const instance_ext_names: [][*:0]const u8 = try allocator.alloc([*:0]const u8, instance_ext_count);
        defer allocator.free(instance_ext_names);
        if (c.SDL_Vulkan_GetInstanceExtensions(screen, &instance_ext_count, @ptrCast(instance_ext_names)) != c.SDL_TRUE) {
            return error.SdlVkGetInstanceExtensionsError;
        }

        var gx: Gx = .init(allocator, .{
            .app_name = @tagName(build.name),
            .app_version = .{
                .major = app_version.major,
                .minor = app_version.minor,
                .patch = app_version.patch,
            },
            .engine_name = @tagName(build.name),
            .engine_version = .{
                .major = app_version.major,
                .minor = app_version.minor,
                .patch = app_version.patch,
            },
            .frames_in_flight = 2,
            .timestamp_queries = tracy.enabled,
            .backend = .{
                .instance_extensions = instance_ext_names,
                .getInstanceProcAddress = @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr()),
                .surface_context = screen,
                .createSurface = &createVulkanSurface,
            },
            .debug = args.named.@"gpu-debug",
        });

        const mb = std.math.pow(u64, 2, 20);
        const color_images: gpu.Memory(.color_image) = .init(&gx, .{
            .name = .{ .str = "Color Images" },
            .size = 16 * mb,
        });
        const upload_queue: ImageUploadQueue = .init(&gx, .{
            .name = .{ .str = "Color Image Upload" },
            .bytes = 16 * mb,
        });

        break :b .{
            .vk = .{
                .gx = gx,
                .upload_queue = upload_queue,
                .color_images = color_images,
            },
        };
    } else b: {
        const renderer_flags: u32 = if (profile) 0 else c.SDL_RENDERER_PRESENTVSYNC;
        break :b .{ .sdl = c.SDL_CreateRenderer(screen, -1, renderer_flags) orelse {
            panic("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        } };
    };
    defer switch (renderer) {
        .sdl => |sr| c.SDL_DestroyRenderer(sr),
        .vk => |*vk| {
            vk.gx.waitIdle();
            vk.deinit(allocator);
        },
    };

    // Load assets
    var assets = try Assets.init(allocator, &renderer);
    defer assets.deinit();

    var game = try Game.init(allocator, &assets);

    // Create initial entities
    var es: Entities = try .init(.{ .gpa = allocator });
    defer es.deinit(allocator);

    // TODO: remember to check usage
    var cb = try CmdBuf.init(.{ .name = "cb", .gpa = allocator, .es = &es });
    defer cb.deinit(allocator, &es);

    game.setupScenario(&es, &cb, .deathmatch_2v2);

    // Run sim
    var delta_s: f32 = 1.0 / 60.0;
    var timer = try std.time.Timer.start();

    // We can use `fx_loop_s` as a time parameter for looping effects without needing extra
    // state everywhere. We loop it at 1000 so that we don't lose precision as the game runs, 1000
    // was chosen so that so long as our effect frequency per second can be any number with three or
    // less digits after the decimal and still loop seemlessly when we reset back to zero.
    var fx_loop_s: f32 = 0.0;
    const max_fx_loop_s: f32 = 1000.0;
    // var warned_memory_usage = false;

    while (true) {
        if (poll(&es, &cb, &game)) {
            std.process.cleanExit();
            return;
        }
        update(&es, &cb, &game, delta_s);
        render(&es, &game, delta_s, fx_loop_s);

        // TODO(mason): we also want a min frame time so we don't get surprising floating point
        // results if it's too close to zero!
        // Adjust our expectd delta time a little every frame. We cap it at `max_frame_time` to
        // prevent e.g. a slow alt tab from messing things up too much.
        const delta_rwa_bias = 0.05;
        const max_frame_time = 1.0 / 30.0;
        const t: f32 = @floatFromInt(timer.lap());
        const last_delta_s = t / std.time.ns_per_s;
        delta_s = lerp(delta_s, @min(last_delta_s, max_frame_time), delta_rwa_bias);
        fx_loop_s = @mod(fx_loop_s + delta_s, max_fx_loop_s);
        if (profile) {
            std.debug.print("frame time: {d}ms ", .{last_delta_s * 1000.0});
            // TODO: ...
            // std.debug.print("entity memory: {}/{}mb ", .{ fba.end_index / (1024 * 1024), fba.buffer.len / (1024 * 1024) });
            std.debug.print("\n", .{});
        }

        // TODO: ...
        // if (fba.end_index >= fba.buffer.len / 4 and !warned_memory_usage) {
        //     std.log.warn(">= 25% of entity memory has been used, consider increasing the size of the fixed buffer allocator", .{});
        //     warned_memory_usage = true;
        // }

        tracy.frameMark(null);
    }
}

fn poll(es: *Entities, cb: *CmdBuf, game: *Game) bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        switch (event.type) {
            c.SDL_QUIT => return true,
            c.SDL_KEYDOWN => switch (event.key.keysym.scancode) {
                c.SDL_SCANCODE_ESCAPE => return true,
                c.SDL_SCANCODE_RETURN => {
                    // Clear invulnerability so you don't have to wait when testing
                    var it = es.iterator(struct { health: *Health });
                    while (it.next(es)) |vw| {
                        vw.health.invulnerable_s = 0.0;
                    }
                },
                c.SDL_SCANCODE_1 => {
                    game.setupScenario(es, cb, .deathmatch_2v2);
                },
                c.SDL_SCANCODE_2 => {
                    game.setupScenario(es, cb, .deathmatch_2v2_no_rocks);
                },
                c.SDL_SCANCODE_3 => {
                    game.setupScenario(es, cb, .deathmatch_2v2_one_rock);
                },
                c.SDL_SCANCODE_4 => {
                    game.setupScenario(es, cb, .deathmatch_1v1);
                },
                c.SDL_SCANCODE_5 => {
                    game.setupScenario(es, cb, .deathmatch_1v1_one_rock);
                },
                c.SDL_SCANCODE_6 => {
                    game.setupScenario(es, cb, .royale_4p);
                },
                else => {},
            },
            else => {},
        }
    }
    return false;
}

fn randomOnCircle(rng: std.Random, radius: f32) Vec2 {
    return Vec2.unit(rng.float(f32) * math.tau).scaled(radius);
}

fn randomInCircleBiased(rng: std.Random, radius: f32) Vec2 {
    return randomOnCircle(rng, radius * rng.float(f32));
}

fn update(
    es: *Entities,
    cb: *CmdBuf,
    game: *Game,
    delta_s: f32,
) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    switch (game.assets.renderer.*) {
        .vk => game.camera.x += 0.1 * delta_s,
        .sdl => {},
    }

    updateInput(es, cb, game);
    updatePhysics(game, es, cb);
    es.forEach("updateGravity", updateGravity, .{
        .es = es,
        .cb = cb,
        .delta_s = delta_s,
    });
    es.forEach("updateSprings", updateSprings, .{});
    es.forEach("updateDamage", updateDamage, .{
        .es = es,
        .game = game,
        .cb = cb,
    });

    es.forEach("updateHealth", updateHealth, .{
        .game = game,
        .cb = cb,
        .delta_s = delta_s,
    });

    es.forEach("updateShip", updateShip, .{
        .game = game,
        .es = es,
        .cb = cb,
        .delta_s = delta_s,
    });

    es.forEach("updateAnimateOnInput", updateAnimateOnInput, .{
        .game = game,
    });
    es.forEach("updateGrappleGun", updateGrappleGun, .{
        .game = game,
        .cb = cb,
        .delta_s = delta_s,
    });
    es.forEach("updateAnimation", updateAnimation, .{
        .cb = cb,
    });
    es.forEach("updateLifetime", updateLifetime, .{
        .cb = cb,
        .delta_s = delta_s,
    });
    es.forEach("updateTurret", updateTurret, .{
        .game = game,
        .cb = cb,
        .delta_s = delta_s,
    });

    exec(es, cb);

    es.updateStats();
}

fn updateGravity(
    ctx: struct {
        delta_s: f32,
        es: *const Entities,
        cb: *CmdBuf,
    },
    rb: *RigidBody,
    transform: *Transform,
    health_opt: ?*Health,
) void {
    // gravity if the rb is outside the ring
    if (transform.getWorldPos().distSq(display_center) > display_radius * display_radius and rb.density < std.math.inf(f32)) {
        const gravity = 500;
        const gravity_v = display_center.minus(transform.getWorldPos()).normalized().scaled(gravity * ctx.delta_s);
        rb.vel.add(gravity_v);
        // punishment for leaving the circle
        if (health_opt) |health| _ = health.damage(ctx.delta_s * 4);
    }

    // transform.move(ctx.es, ctx.cb, rb.vel.scaled(ctx.delta_s));
    transform.move(ctx.es, rb.vel.scaled(ctx.delta_s));
    transform.rotate(ctx.es, .fromAngle(rb.rotation_vel * ctx.delta_s));
}

// TODO(mason): take velocity from before impact? i may have messed that up somehow
fn updateHealth(
    ctx: struct {
        cb: *CmdBuf,
        game: *Game,
        delta_s: f32,
    },
    health: *Health,
    rb_opt: ?*const RigidBody,
    transform_opt: ?*const Transform,
    player_index_opt: ?*const PlayerIndex,
    team_index_opt: ?*const TeamIndex,
    entity: Entity,
) void {
    const cb = ctx.cb;
    const game = ctx.game;
    const rng = game.rng.random();
    const delta_s = ctx.delta_s;

    if (health.hp <= 0) {
        // spawn explosion here
        if (transform_opt) |transform| {
            const e = Entity.reserve(cb);
            e.add(cb, Lifetime, .{
                .seconds = 100,
            });
            e.add(cb, Transform, .{
                .pos = transform.getWorldPos(),
            });
            e.add(cb, RigidBody, .{
                .vel = if (rb_opt) |rb| rb.vel else .{ .x = 0, .y = 0 },
                .rotation_vel = 0,
                .radius = 32,
                .density = 0.001,
            });
            e.add(cb, Animation.Playback, .{
                .index = game.explosion_animation,
                .destroys_entity = true,
            });
        }

        // If this is a player controlled ship, spawn a new ship for the player using this
        // ship's input before we destroy it!
        if (player_index_opt) |player_index| {
            if (team_index_opt) |team_index| {
                // give player their next ship
                const team = &game.teams[@intFromEnum(team_index.*)];
                if (team.ship_progression_index >= team.ship_progression.len) {
                    const already_over = game.over();
                    team.players_alive -= 1;
                    if (game.over() and !already_over) {
                        const happy_team = game.aliveTeam();
                        game.spawnTeamVictory(cb, display_center, happy_team);
                    }
                } else {
                    const new_angle = math.tau * rng.float(f32);
                    const new_pos = display_center.plus(Vec2.unit(new_angle).scaled(display_radius));
                    const facing_angle = new_angle + math.pi;
                    game.createShip(cb, player_index.*, team_index.*, new_pos, facing_angle);
                }
            }
        }

        // Destroy the vw
        entity.destroy(cb);
    }

    // Regen health
    const max_regen = health.regen_ratio * health.max_hp;
    const regen_speed = max_regen / health.regen_s;
    if (health.regen_cooldown_s <= 0.0 and health.hp < max_regen) {
        health.hp = @min(health.hp + regen_speed * delta_s, max_regen);
    }
    health.regen_cooldown_s = @max(health.regen_cooldown_s - delta_s, 0.0);

    // Update invulnerability
    health.invulnerable_s = @max(health.invulnerable_s - delta_s, 0.0);
}

fn updateInput(es: *Entities, cb: *CmdBuf, game: *Game) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Update input
    for (&game.input_state, &game.control_schemes) |*input_state, *control_scheme| {
        input_state.update();
        input_state.applyControlScheme(control_scheme, &game.controllers);
    }

    for (&game.input_state) |*input_state| {
        if (input_state.isAction(.start, .positive, .activated)) {
            game.setupScenario(es, cb, .deathmatch_1v1_one_rock);
        }
    }

    es.forEach("blockInvulnerableFire", blockInvulnerableFire, .{ .game = game });
}

fn blockInvulnerableFire(
    ctx: struct {
        game: *Game,
    },
    player_index: *const PlayerIndex,
    health: *const Health,
) void {
    if (health.invulnerable_s > 0.0) {
        var input_state = &ctx.game.input_state[@intFromEnum(player_index.*)];
        input_state.setAction(.fire, .positive, .inactive);
    }
}

fn updatePhysics(game: *Game, es: *Entities, cb: *CmdBuf) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    const rng = game.rng.random();
    var it = es.iterator(struct {
        rb: *RigidBody,
        transform: *const Transform,
        collider: *const Collider,
        health: ?*Health,
        front_shield: ?*const FrontShield,
        hook: ?*const Hook,
        entity: Entity,
    });
    while (it.next(es)) |vw| {
        var other_it = it;
        while (other_it.next(es)) |other| {
            if (!Collider.interacts.get(vw.collider.layer, other.collider.layer)) continue;

            const added_radii = vw.rb.radius + other.rb.radius;
            if (vw.transform.getWorldPos().distSq(other.transform.getWorldPos()) > added_radii * added_radii) continue;

            // calculate normal
            const normal = other.transform.getWorldPos().minus(vw.transform.getWorldPos()).normalized();
            // calculate relative velocity
            const rv = other.rb.vel.minus(vw.rb.vel);
            // calculate relative velocity in terms of the normal direction
            const vel_along_normal = rv.innerProd(normal);
            // do not resolve if velocities are separating
            if (vel_along_normal > 0) continue;
            // calculate restitution
            const e = @min(vw.collider.collision_damping, other.collider.collision_damping);
            // calculate impulse scalar
            var j: f32 = -(1.0 + e) * vel_along_normal;
            const my_mass = vw.rb.mass();
            const other_mass = other.rb.mass();
            j /= 1.0 / my_mass + 1.0 / other_mass;
            // apply impulse
            const impulse_mag = normal.scaled(j);
            const impulse = impulse_mag.scaled(1 / my_mass);
            const other_impulse = impulse_mag.scaled(1 / other_mass);
            vw.rb.vel.sub(impulse);
            other.rb.vel.add(other_impulse);

            // Deal HP damage relative to the change in velocity.
            // A very gentle bonk is something like impulse 20, while a
            // very hard bonk is around 300.
            // The basic ranger ship has 80 HP.
            var total_damage: f32 = 0;
            const max_shield = 1.0;
            if (vw.health) |entity_health| {
                if (other.health == null or other.health.?.invulnerable_s <= 0.0) {
                    var shield_scale: f32 = 0.0;
                    if (vw.front_shield != null) {
                        const dot = vw.transform.getForward().innerProd(normal);
                        shield_scale = @max(dot, 0.0);
                    }
                    const damage = lerp(1.0, 1.0 - max_shield, std.math.pow(f32, shield_scale, 1.0 / 2.0)) * remap(20, 300, 0, 80, impulse.mag());
                    if (damage >= 2) {
                        total_damage += entity_health.damage(damage);
                    }
                }
            }
            if (other.health) |other_health| {
                if (vw.health == null or vw.health.?.invulnerable_s <= 0.0) {
                    var shield_scale: f32 = 0.0;
                    if (other.front_shield != null) {
                        const dot = other.transform.getForward().innerProd(normal);
                        shield_scale = @max(-dot, 0.0);
                    }
                    const damage = lerp(1.0, 1.0 - max_shield, std.math.pow(f32, shield_scale, 1.0 / 2.0)) * remap(20, 300, 0, 80, other_impulse.mag());
                    if (damage >= 2) {
                        total_damage += other_health.damage(damage);
                    }
                }
            }

            const shrapnel_amt: u32 = @intFromFloat(
                @floor(remapClamped(0, 100, 0, 30, total_damage)),
            );
            const shrapnel_center = vw.transform.getWorldPos().plus(other.transform.getWorldPos()).scaled(0.5);
            const avg_vel = vw.rb.vel.plus(other.rb.vel).scaled(0.5);
            for (0..shrapnel_amt) |_| {
                const shrapnel_animation = game.shrapnel_animations[
                    rng.uintLessThanBiased(usize, game.shrapnel_animations.len)
                ];
                // Spawn slightly off center from collision point.
                const random_offset = randomInCircleBiased(rng, 10.0);
                // Give them random velocities.
                const base_vel = if (rng.boolean()) vw.rb.vel else other.rb.vel;
                const random_vel = randomInCircleBiased(rng, base_vel.mag() * 2);
                const piece = Entity.reserve(cb);
                piece.add(cb, Lifetime, .{
                    .seconds = 1.5 + rng.float(f32) * 1.0,
                });
                piece.add(cb, Transform, .{
                    .pos = shrapnel_center.plus(random_offset),
                    .rot = .fromAngle(math.tau * rng.float(f32)),
                });
                piece.add(cb, RigidBody, .{
                    .vel = avg_vel.plus(random_vel),
                    .rotation_vel = math.tau * rng.float(f32),
                    .radius = game.animationRadius(shrapnel_animation),
                    .density = 0.001,
                });
                piece.add(cb, Animation.Playback, .{
                    .index = shrapnel_animation,
                    .destroys_entity = true,
                });
            }

            // TODO: why does it fly away when attached? well partly it's that i set the distance to 0 when
            // the current distance is greater...fixing that
            // TODO: don't always attach to the center? this is easy to do, but, it won't cause
            // rotation the way you'd expect at the moment since the current physics system doesn't
            // have opinions on rotation. We can add that though!
            {
                var hooked = false;
                if (vw.hook) |hook| {
                    vw.entity.remove(cb, Hook);
                    vw.entity.add(cb, Spring, .{
                        .start = vw.entity,
                        .end = other.entity,
                        .k = hook.k,
                        .length = vw.transform.getWorldPos().dist(other.transform.getWorldPos()),
                        .damping = hook.damping,
                    });
                    hooked = true;
                }
                if (other.hook) |hook| {
                    other.entity.remove(cb, Hook);
                    other.entity.add(cb, Spring, .{
                        .start = vw.entity,
                        .end = other.entity,
                        .k = hook.k,
                        .length = vw.transform.getWorldPos().dist(other.transform.getWorldPos()),
                        .damping = hook.damping,
                    });
                    hooked = true;
                }
                // TODO: continue afte first one..?
                if (hooked) {
                    continue;
                }
            }
        }
    }
}

// TODO: springs were already disabled
fn updateSprings(ctx: struct {}, spring: *Spring) void {
    _ = ctx;
    _ = spring;

    // // TODO: crashes if either end has been deleted right now. we may wanna actually make
    // // checking if an entity is valid or not a feature if there's not a bette way to handle this?
    // var start_trans = es.get(vw.spring.start, .transform) orelse {
    //     std.log.err("spring connections require transform, destroying spring entity", .{});
    //     it.swapRemove();
    //     continue;
    // };

    // var end_trans = es.get(vw.spring.end, .transform) orelse {
    //     std.log.err("spring connections require transform, destroying spring entity", .{});
    //     it.swapRemove();
    //     continue;
    // };
    // var start_rb = es.get(vw.spring.start, .rb) orelse {
    //     std.log.err("spring connections require rb, destroying spring entity", .{});
    //     it.swapRemove();
    //     continue;
    // };

    // var end_rb = es.get(vw.spring.end, .rb) orelse {
    //     std.log.err("spring connections require rb, destroying spring entity", .{});
    //     it.swapRemove();
    //     continue;
    // };

    // var delta = end_trans.pos.minus(start_trans.pos);
    // const dir = delta.normalized();

    // // TODO: min length 0 right now, could make min and max (before force) settable though?
    // // const x = delta.length() - spring.length;
    // const x = @max(delta.length() - vw.spring.length, 0.0);
    // const spring_force = vw.spring.k * x;

    // const relative_vel = end_rb.vel.innerProd(dir) - start_rb.vel.innerProd(dir);
    // const start_b = @sqrt(vw.spring.damping * 4.0 * start_rb.mass() * vw.spring.k);
    // const start_damping_force = start_b * relative_vel;
    // const end_b = @sqrt(vw.spring.damping * 4.0 * end_rb.mass() * vw.spring.k);
    // const end_damping_force = end_b * relative_vel;

    // const start_impulse = (start_damping_force + spring_force) * delta_s;
    // const end_impulse = (end_damping_force + spring_force) * delta_s;
    // start_rb.vel.add(dir.scaled(start_impulse / start_rb.mass()));
    // end_rb.vel.add(dir.scaled(-end_impulse / start_rb.mass()));
}

fn updateDamage(
    ctx: struct {
        es: *Entities,
        game: *Game,
        cb: *CmdBuf,
    },
    damage: *const Damage,
    rb: *const RigidBody,
    transform: *Transform,
    entity: Entity,
) void {
    const rng = ctx.game.rng.random();
    var health_it = ctx.es.iterator(struct {
        health: *Health,
        rb: *const RigidBody,
        transform: *const Transform,
    });
    while (health_it.next(ctx.es)) |health_vw| {
        if (health_vw.transform.getWorldPos().distSq(transform.getWorldPos()) <
            health_vw.rb.radius * health_vw.rb.radius + rb.radius * rb.radius)
        {
            if (health_vw.health.damage(damage.hp) > 0.0) {
                // spawn shrapnel here
                const shrapnel_animation = ctx.game.shrapnel_animations[
                    rng.uintLessThanBiased(usize, ctx.game.shrapnel_animations.len)
                ];
                const random_vector = randomOnCircle(rng, rb.vel.mag() * 0.2);
                const e = Entity.reserve(ctx.cb);
                e.add(ctx.cb, Lifetime, .{
                    .seconds = 1.5 + rng.float(f32) * 1.0,
                });
                e.add(ctx.cb, Transform, .{
                    .pos = health_vw.transform.getWorldPos(),
                    .rot = .fromAngle(math.tau * rng.float(f32)),
                });
                e.add(ctx.cb, RigidBody, .{
                    .vel = health_vw.rb.vel.plus(rb.vel.scaled(0.2)).plus(random_vector),
                    .rotation_vel = math.tau * rng.float(f32),
                    .radius = ctx.game.animationRadius(shrapnel_animation),
                    .density = 0.001,
                });
                e.add(ctx.cb, Animation.Playback, .{
                    .index = shrapnel_animation,
                    .destroys_entity = true,
                });

                entity.destroy(ctx.cb);
            }
        }
    }

    transform.setRot(ctx.es, .look(rb.vel.normalized()));
}

fn updateShip(
    ctx: struct {
        game: *Game,
        es: *Entities,
        cb: *CmdBuf,
        delta_s: f32,
    },
    ship: *const Ship,
    rb: *RigidBody,
    transform: *Transform,
    player_index: *const PlayerIndex,
) void {
    const input_state = &ctx.game.input_state[@intFromEnum(player_index.*)];
    if (ship.omnithrusters) {
        rb.vel.add(.{
            .x = input_state.getAxis(.thrust_x) * ship.thrust * ctx.delta_s,
            .y = input_state.getAxis(.thrust_y) * ship.thrust * ctx.delta_s,
        });
    } else {
        // convert to 1.0 or 0.0
        transform.rotate(
            ctx.es,
            .fromAngle(input_state.getAxis(.turn) * ship.turn_speed * ctx.delta_s),
        );

        const thrust_input: f32 = @floatFromInt(@intFromBool(input_state.isAction(.thrust_forward, .positive, .active)));
        const forward = transform.getForward();
        const thrust = forward.scaled(thrust_input * ship.thrust * ctx.delta_s);
        rb.vel.add(thrust);
    }
}

fn updateAnimateOnInput(
    ctx: struct {
        game: *Game,
    },
    player_index: *const PlayerIndex,
    animate_on_input: *const AnimateOnInput,
    animation: *Animation.Playback,
) void {
    const input_state = &ctx.game.input_state[@intFromEnum(player_index.*)];
    if (input_state.isAction(animate_on_input.action, animate_on_input.direction, .activated)) {
        animation.* = .{
            .index = animate_on_input.activated,
        };
    } else if (input_state.isAction(animate_on_input.action, animate_on_input.direction, .deactivated)) {
        animation.* = .{
            .index = animate_on_input.deactivated,
        };
    }
}

fn updateGrappleGun(
    ctx: struct {
        game: *Game,
        cb: *CmdBuf,
        delta_s: f32,
    },
    gg: *GrappleGun,
    player_index: *const PlayerIndex,
    rb: *const RigidBody,
    transform: *const Transform,
    entity: Entity,
) void {
    const delta_s = ctx.delta_s;
    const game = ctx.game;
    const cb = ctx.cb;
    // TODO: break out cooldown logic or no?
    gg.cooldown_s -= delta_s;
    const input_state = &game.input_state[@intFromEnum(player_index.*)];
    if (input_state.isAction(.fire, .positive, .activated) and gg.cooldown_s <= 0) {
        gg.cooldown_s = gg.max_cooldown_s;

        // TODO: increase cooldown_s?
        if (gg.live) |live| {
            for (live.joints) |piece| {
                piece.destroy(cb);
            }
            for (live.springs) |piece| {
                piece.destroy(cb);
            }
            live.hook.destroy(cb);
            gg.live = null;
        } else {
            // TODO: behave sensibly if the ship that fired it dies...right now crashes cause
            // one side of the spring has a bad generation
            // TODO: change sprite!
            // TODO: make lower mass or something lol
            // TODO: how do i make it connect? we could replace the hook with the thing it's connected
            // to when it hits, but, then it'd always connect to the center. so really we wanna
            // create a new spring that's very strong between the hook and the thing it's connected to.
            // this means we need to either add a new spring later, or allow for disconnected springs.
            // if we had addcomponent we could have a hook that dynamically creates a spring on contact,
            // that's what we actually want!
            // for now though lets just make the spring ends optional and make a note that this is a good
            // place for addcomponent.
            // TODO: then again, addcomponent is easy to add. we just create a new entity move over the components
            // then delete the old one, and remap the handle.
            gg.live = .{
                .joints = undefined,
                .springs = undefined,
                .hook = undefined,
            };

            // TODO: we COULD add colliders to joints and if it was dense enough you could wrap the rope around things...
            var dir = Rotor2.fromAngle(gg.angle).timesVec2(transform.getForward());
            const vel = rb.vel;
            const segment_len = 50.0;
            var pos = transform.getWorldPos().plus(dir.scaled(segment_len));
            for (0..gg.live.?.joints.len) |i| {
                const joint = Entity.reserve(cb);
                joint.add(cb, Transform, .{
                    .pos = pos,
                });
                joint.add(cb, RigidBody, .{
                    .vel = vel,
                    .radius = 2,
                    .density = 0.001,
                });
                // TODO: ...
                // .sprite = game.bullet_small,
                gg.live.?.joints[i] = joint;
                pos.add(dir.scaled(segment_len));
            }
            // TODO: i think the damping code is broken, if i set this to be critically damped
            // it explodes--even over damping shouldn't do that it should slow things down
            // extra!
            // TODO: ah yeah, damping prevents len from going to low for some reason??
            const hook = Hook{
                .damping = 0.0,
                .k = 100.0,
            };
            const hook_entity = Entity.reserve(cb);
            hook_entity.add(cb, Transform, .{
                .pos = pos,
            });
            hook_entity.add(cb, RigidBody, .{
                .vel = vel,
                .rotation_vel = 0,
                .radius = 2,
                .density = 0.001,
            });
            hook_entity.add(cb, Collider, .{
                .collision_damping = 0,
                .layer = .hook,
            });
            hook_entity.add(cb, Hook, hook);
            // TODO: ...
            // .sprite = game.bullet_small,
            // TODO: why nullable?
            gg.live.?.hook = hook_entity;
            for (0..(gg.live.?.springs.len)) |i| {
                const spring = Entity.reserve(cb);
                spring.add(cb, Spring, .{
                    .start = if (i == 0)
                        entity
                    else
                        gg.live.?.joints[i - 1],
                    .end = if (i < gg.live.?.joints.len)
                        gg.live.?.joints[i]
                    else
                        gg.live.?.hook,
                    .k = hook.k,
                    .length = segment_len,
                    .damping = hook.damping,
                });
                gg.live.?.springs[i] = spring;
            }
        }
    }
}

fn updateAnimation(
    ctx: struct { cb: *CmdBuf },
    animation: *const Animation.Playback,
    entity: Entity,
) void {
    if (animation.destroys_entity and animation.index == .none) {
        entity.destroy(ctx.cb);
    }
}

fn updateLifetime(
    ctx: struct {
        cb: *CmdBuf,
        delta_s: f32,
    },
    lifetime: *Lifetime,
    entity: Entity,
) void {
    lifetime.seconds -= ctx.delta_s;
    if (lifetime.seconds <= 0) {
        entity.destroy(ctx.cb);
    }
}

fn updateTurret(
    ctx: struct {
        game: *Game,
        cb: *CmdBuf,
        delta_s: f32,
    },
    turret: *Turret,
    transform: *const Transform,
    player_index: *const PlayerIndex,
    rb_opt: ?*const RigidBody,
) void {
    const game = ctx.game;
    const cb = ctx.cb;
    const delta_s = ctx.delta_s;

    var vel = transform.getForward().scaled(turret.projectile_speed);
    if (rb_opt) |rb| vel.add(rb.vel);
    var sprite = game.bullet_small;
    const fire_pos_local: Vec2 = .{
        .x = 0.0,
        .y = turret.radius + turret.projectile_radius,
    };
    var rotation: Mat2x3 = .identity;
    if (rb_opt) |rb| {
        if (turret.aim_opposite_movement) {
            vel = .zero;
            sprite = game.bullet_shiny;
            rotation = .rotation(.look(rb.vel.normalized().normal()));
        }
    }
    const fire_pos = transform.world_from_model.times(rotation).timesPoint(fire_pos_local);
    const ready = switch (turret.cooldown) {
        .time => |*time| r: {
            time.current_s -= delta_s;
            break :r time.current_s <= 0;
        },
        .distance => |dist| if (dist.last_pos) |last_pos|
            fire_pos.distSq(last_pos) >= dist.min_sq
        else
            true,
    };
    const input_state = &game.input_state[@intFromEnum(player_index.*)];
    if (input_state.isAction(.fire, .positive, .active) and ready) {
        switch (turret.cooldown) {
            .time => |*time| time.current_s = time.max_s,
            .distance => |*dist| dist.last_pos = fire_pos,
        }
        // TODO(mason): just make separate component for wall
        const e = Entity.reserve(cb);
        e.add(cb, Damage, .{
            .hp = turret.projectile_damage,
        });
        e.add(cb, Transform, .{
            .pos = fire_pos,
            .rot = .look(vel.normalized()),
        });
        e.add(cb, RigidBody, .{
            .vel = vel,
            .rotation_vel = 0,
            .radius = turret.projectile_radius,
            // TODO(mason): modify math to accept 0 and inf mass
            .density = turret.projectile_density,
        });
        e.add(cb, Sprite.Index, sprite);
        e.add(cb, Collider, .{
            // Lasers gain energy when bouncing off of rocks
            .collision_damping = 1,
            .layer = .projectile,
        });
        e.add(cb, Lifetime, .{
            .seconds = turret.projectile_lifetime,
        });
    }
}

pub fn exec(es: *Entities, cb: *CmdBuf) void {
    Transform.Exec.immediate(es, cb);
}

// TODO(mason): allow passing in const for rendering to make sure no modifications
fn render(es: *Entities, game: *const Game, delta_s: f32, fx_loop_s: f32) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    switch (game.assets.renderer.*) {
        .sdl => |sdl| {
            // This was added for the flash effect and then not used since it already requires a timer
            // state. We'll be wanting it later and I don't feel like deleting and retyping the explanation
            // for it.
            _ = fx_loop_s;

            // Clear screen
            {
                const clear_zone = Zone.begin(.{ .src = @src(), .name = "clear" });
                defer clear_zone.end();
                sdlAssertZero(c.SDL_SetRenderDrawColor(sdl, 0x00, 0x00, 0x00, 0xff));
                sdlAssertZero(c.SDL_RenderClear(sdl));
            }

            // Draw stars
            {
                const stars_zone = Zone.begin(.{ .src = @src(), .name = "stars" });
                defer stars_zone.end();

                for (game.stars) |star| {
                    const sprite = game.assets.sprite(switch (star.kind) {
                        .small => game.star_small,
                        .large => game.star_large,
                        .planet_red => game.planet_red,
                    });
                    renderCopy(.{
                        .renderer = sdl,
                        .tex = sprite.tints[0],
                        .rad = 0.0,
                        .pos = .{ .x = @floatFromInt(star.x), .y = @floatFromInt(star.y) },
                        .size = .{ .x = @floatFromInt(sprite.rect.w), .y = @floatFromInt(sprite.rect.h) },
                    });
                }
            }

            // Draw ring
            {
                const ring_zone = Zone.begin(.{ .src = @src(), .name = "ring" });
                defer ring_zone.end();

                const sprite = game.assets.sprite(game.ring_bg);
                renderCopy(.{
                    .renderer = sdl,
                    .tex = sprite.tints[0],
                    .rad = 0.0,
                    .pos = display_center,
                    .size = .{ .x = @floatFromInt(sprite.rect.w), .y = @floatFromInt(sprite.rect.h) },
                });
            }

            es.forEach("renderAnimations", renderAnimations, .{
                .assets = game.assets,
                .es = es,
                .delta_s = delta_s,
                .renderer = sdl,
            });
            es.forEach("renderHealthBar", renderHealthBar, .{
                .renderer = sdl,
            });
            es.forEach("renderSprite", renderSprite, .{
                .game = game,
                .renderer = sdl,
            });
            es.forEach("renderSpring", renderSpring, .{
                .es = es,
                .renderer = sdl,
            });

            // Draw the ships in the bank.
            {
                const bank_zone = Zone.begin(.{ .src = @src(), .name = "bank" });
                defer bank_zone.end();

                const row_height = 64;
                const col_width = 64;
                const top_left: Vec2 = .{ .x = 20, .y = 20 };

                for (game.teams, 0..) |team, team_index| {
                    {
                        const sprite = game.assets.sprite(game.particle);
                        const pos = top_left.plus(.{
                            .x = col_width * @as(f32, @floatFromInt(team_index)),
                            .y = 0,
                        });
                        renderCopy(.{
                            .renderer = sdl,
                            .tex = sprite.getTint(@enumFromInt(team_index)),
                            .pos = pos,
                            .size = sprite.size(),
                        });
                    }
                    for (team.ship_progression, 0..) |class, display_prog_index| {
                        const dead = team.ship_progression_index > display_prog_index;
                        if (dead) continue;

                        const sprite = game.assets.sprite(game.shipLifeSprite(class));
                        const pos = top_left.plus(.{
                            .x = col_width * @as(f32, @floatFromInt(team_index)),
                            .y = display_height - row_height * @as(f32, @floatFromInt(display_prog_index)),
                        });
                        renderCopy(.{
                            .renderer = sdl,
                            .tex = sprite.getTint(@enumFromInt(team_index)),
                            .pos = pos,
                            .size = sprite.size().scaled(0.5),
                        });
                    }
                }
            }

            {
                const present_zone = Zone.begin(.{ .src = @src(), .name = "present" });
                defer present_zone.end();
                c.SDL_RenderPresent(sdl);
            }
        },
        .vk => |*vk| {
            // Write the camera position
            const frame_layout = game.assets.sprite_storage_layout.frame(vk.gx.frame);
            var global_writer = frame_layout.global.writer(game.assets.sprite_storage_buffer);
            global_writer.writeStruct(SpriteGlobal{
                .world_to_view = .translation(game.camera.negated()).multiplied(.rotation()),
            }) catch |err| @panic(@errorName(err));

            vk.gx.beginFrame();
            const framebuf = vk.gx.acquireNextImage(.{
                .width = display_width,
                .height = display_height,
            });
            const render_game: gpu.CmdBuf = .init(&vk.gx, .{
                .name = "Render Game",
                .src = @src(),
            });
            render_game.beginRendering(&vk.gx, .{
                .color_attachments = &.{
                    .init(.{
                        .load_op = .{ .clear_color = .{ 0.0, 0.0, 0.0, 1.0 } },
                        .view = framebuf.view,
                    }),
                },
                .viewport = .{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(framebuf.extent.width),
                    .height = @floatFromInt(framebuf.extent.height),
                    .min_depth = 0.0,
                    .max_depth = 1.0,
                },
                .scissor = .{
                    .offset = .{ .x = 0, .y = 0 },
                    .extent = framebuf.extent,
                },
                .area = .{
                    .offset = .{ .x = 0, .y = 0 },
                    .extent = framebuf.extent,
                },
            });

            render_game.bindPipeline(&vk.gx, game.assets.sprite_pipeline);
            render_game.bindDescSet(
                &vk.gx,
                game.assets.sprite_pipeline,
                game.assets.sprite_desc_sets[vk.gx.frame],
            );
            render_game.draw(&vk.gx, .{
                .vertex_count = 4,
                .instance_count = 1,
                .first_vertex = 0,
                .first_instance = 0,
            });

            // XXX: ...
            for (game.stars) |star| {
                const sprite = game.assets.sprite(switch (star.kind) {
                    .small => game.star_small,
                    .large => game.star_large,
                    .planet_red => game.planet_red,
                });
                // XXX: ...
                _ = sprite;
                // renderCopy(.{
                //     .renderer = sdl,
                //     .tex = sprite.tints[0],
                //     .rad = 0.0,
                //     .pos = .{ .x = @floatFromInt(star.x), .y = @floatFromInt(star.y) },
                //     .size = .{ .x = @floatFromInt(sprite.rect.w), .y = @floatFromInt(sprite.rect.h) },
                // });
            }

            render_game.endRendering(&vk.gx);
            render_game.submit(&vk.gx);
            vk.gx.endFrame(.{});
        },
    }
}

fn renderAnimations(
    ctx: struct {
        assets: *const Assets,
        es: *Entities,
        delta_s: f32,
        renderer: *c.SDL_Renderer,
    },
    entity: Entity,
    rb: *const RigidBody,
    transform: *const Transform,
    animation: *Animation.Playback,
    team_index_opt: ?*const TeamIndex,
) void {
    const es = ctx.es;
    const assets = ctx.assets;
    const delta_s = ctx.delta_s;

    // Skip rendering if flashing, or if any parent is flashing.
    //
    // We should probably make the sprites half opacity instead of turning them off when
    // flashing for a less jarring effect, but that is difficult right now w/ SDL as our
    // renderer.
    {
        var curr = entity;
        while (true) {
            if (curr.get(es, Health)) |health| {
                if (health.invulnerable_s > 0.0) {
                    var flashes_ps: f32 = 2;
                    if (health.invulnerable_s < 0.25 * std.math.round(Health.max_invulnerable_s * flashes_ps) / flashes_ps) {
                        flashes_ps = 4;
                    }
                    if (@sin(flashes_ps * std.math.tau * health.invulnerable_s) > 0.0) {
                        return;
                    }
                }
            }

            if (curr.get(es, Node)) |node| {
                if (node.parent.unwrap()) |parent| {
                    curr = parent;
                    continue;
                }
            }

            break;
        }
    }

    if (animation.index != .none) {
        const frame = assets.animate(animation, delta_s);
        const unscaled_sprite_size = frame.sprite.size();
        const sprite_radius = (unscaled_sprite_size.x + unscaled_sprite_size.y) / 4.0;
        const size_coefficient = rb.radius / sprite_radius;
        const sprite_size = unscaled_sprite_size.scaled(size_coefficient);
        renderCopy(.{
            .renderer = ctx.renderer,
            .tex = frame.sprite.getTint(if (team_index_opt) |ti| ti.* else null),
            .rad = transform.world_from_model.getRotation() + frame.angle,
            .pos = transform.getWorldPos(),
            .size = sprite_size,
        });
    }
}

fn renderHealthBar(
    ctx: struct { renderer: *c.SDL_Renderer },
    health: *const Health,
    rb: *const RigidBody,
    transform: *const Transform,
) void {
    const renderer = ctx.renderer;

    if (health.hp >= health.max_hp) return;

    const health_bar_size: Vec2 = .{ .x = 32, .y = 4 };
    var start = transform.getWorldPos().minus(health_bar_size.scaled(0.5)).floored();
    start.y = display_height - start.y;
    start.y -= rb.radius + health_bar_size.y;
    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0xff, 0xff, 0xff, 0xff));
    sdlAssertZero(c.SDL_RenderFillRect(renderer, &sdlRect(
        start.minus(.{ .x = 1, .y = 1 }),
        health_bar_size.plus(.{ .x = 2, .y = 2 }),
    )));
    const hp_percent = health.hp / health.max_hp;
    if (hp_percent >= health.regen_ratio) {
        sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0x00, 0x94, 0x13, 0xff));
    } else if (health.regen_cooldown_s > 0.0) {
        sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0xe2, 0x00, 0x03, 0xff));
    } else {
        sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0xff, 0x7d, 0x03, 0xff));
    }
    sdlAssertZero(c.SDL_RenderFillRect(renderer, &sdlRect(
        start,
        .{ .x = health_bar_size.x * hp_percent, .y = health_bar_size.y },
    )));
}

fn renderSprite(
    ctx: struct { game: *const Game, renderer: *c.SDL_Renderer },
    sprite_index: *const Sprite.Index,
    rb_opt: ?*const RigidBody,
    transform: *const Transform,
    team_index: ?*const TeamIndex,
) void {
    const assets = ctx.game.assets;
    const renderer = ctx.renderer;
    // TODO(mason): sort draw calls somehow (can the sdl renderer do depth buffers?)
    const sprite = assets.sprite(sprite_index.*);
    const unscaled_sprite_size = sprite.size();
    const sprite_radius = (unscaled_sprite_size.x + unscaled_sprite_size.y) / 4.0;
    const size_coefficient = if (rb_opt) |rb| rb.radius / sprite_radius else 1.0;
    const sprite_size = unscaled_sprite_size.scaled(size_coefficient);
    renderCopy(.{
        .renderer = renderer,
        .tex = sprite.getTint(if (team_index) |ti| ti.* else null),
        .rad = transform.world_from_model.getRotation(),
        .pos = transform.getWorldPos(),
        .size = sprite_size,
    });
}

fn renderSpring(ctx: struct {
    es: *const Entities,
    renderer: *c.SDL_Renderer,
}, spring: *const Spring) void {
    const es = ctx.es;
    const renderer = ctx.renderer;
    // TODO(mason): don't draw springs, have a themed grapple effect that is its own components and
    // gets drawn from spring start to end. we may have other uses for springs that may not look the
    // same!
    const start = (spring.start.get(es, Transform) orelse return).getWorldPos();
    const end = (spring.end.get(es, Transform) orelse return).getWorldPos();
    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0xff, 0xff, 0xff, 0xff));
    sdlAssertZero(c.SDL_RenderDrawLine(
        renderer,
        @intFromFloat(@floor(start.x)),
        @intFromFloat(@floor(start.y)),
        @intFromFloat(@floor(end.x)),
        @intFromFloat(@floor(end.y)),
    ));
}

const Team = struct {
    ship_progression_index: u32,
    ship_progression: []const Ship.Class,
    players_alive: u2,
};

// TODO(mason): what types of errors are possible?
pub fn sdlAssertZero(ret: c_int) void {
    if (ret == 0) return;
    panic("sdl function returned an error: {s}", .{c.SDL_GetError()});
}

const PlayerIndex = enum(u2) { _ };
const TeamIndex = enum(u2) { _ };

const Damage = struct {
    hp: f32,
};

/// A spring connecting two entities.
///
/// You can simulate a rod by choosing a high spring constant and setting the damping factor to 1.0.
const Spring = struct {
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

const Hook = struct {
    damping: f32,
    k: f32,
};

pub const FrontShield = struct {};

const Lifetime = struct {
    seconds: f32,
};

const Animation = struct {
    /// Index into frames array
    start: u32,
    /// Number of frames elements used in this animation.
    len: u32,
    /// After finishing, will jump to this next animation (which may be
    /// itself, in which case it will loop).
    next: Index,
    /// frames per second
    fps: f32,
    angle: f32 = 0.0,

    /// Index into animations array.
    const Index = enum(u32) {
        none = math.maxInt(u32),
        _,
    };

    const Playback = struct {
        index: Index,
        /// number of seconds passed since Animation start.
        time_passed: f32 = 0,
        destroys_entity: bool = false,
    };
};

const Cooldown = union(enum) {
    time: struct {
        max_s: f32,
        current_s: f32 = 0.0,
    },
    distance: struct {
        min_sq: f32,
        last_pos: ?Vec2 = null,
    },
};

const Turret = struct {
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

const GrappleGun = struct {
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

const AnimateOnInput = struct {
    action: input_system.Action,
    direction: input_system.Direction,
    activated: Animation.Index,
    deactivated: Animation.Index,
};

const RigidBody = struct {
    fn mass(self: RigidBody) f32 {
        return self.density * math.pi * self.radius * self.radius;
    }

    /// pixels per second
    vel: Vec2 = .{ .x = 0, .y = 0 },
    /// radians per second
    rotation_vel: f32 = 0.0,
    radius: f32,
    // TODO(mason): why density and not inverse mass? probably a good reason i just wanna understand
    // gotta look at how it's used.
    density: f32,
};

const Collider = struct {
    const Layer = enum {
        vehicle,
        hazard,
        projectile,
        hook,
    };
    const interacts: SymmetricMatrix(Layer, bool) = interacts: {
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

const Health = struct {
    const max_invulnerable_s: f32 = 4.0;

    hp: f32,
    max_hp: f32,
    max_regen_cooldown_s: f32 = 1.5,
    regen_cooldown_s: f32 = 0.0,
    regen_ratio: f32 = 1.0 / 3.0,
    regen_s: f32 = 2.0,
    invulnerable_s: f32 = max_invulnerable_s,

    fn damage(self: *@This(), amount: f32) f32 {
        if (self.invulnerable_s <= 0.0) {
            self.hp -= amount;
            self.regen_cooldown_s = self.max_regen_cooldown_s;
            return amount;
        } else {
            return 0;
        }
    }
};

const Ship = struct {
    /// radians per second
    turn_speed: f32,
    /// pixels per second squared
    thrust: f32,
    omnithrusters: bool = false,

    class: Class,

    const Class = enum {
        ranger,
        militia,
        triangle,
        kevin,
        wendy,
    };
};

const Sprite = struct {
    tints: []*c.SDL_Texture,
    rect: c.SDL_Rect,
    image: ?gpu.Image(.color),

    // If this sprite supports tinting, returns the tint. Otherwise returns the default tint.
    fn getTint(self: *const @This(), index: ?TeamIndex) *c.SDL_Texture {
        if (index != null and self.tints.len > 1) {
            return self.tints[@intFromEnum(index.?)];
        }
        return self.tints[0];
    }

    /// Index into the sprites array.
    const Index = enum(u32) {
        _,
    };

    fn deinit(self: *@This(), allocator: Allocator, renderer: *Renderer) void {
        switch (renderer.*) {
            .vk => |*vk| self.image.?.deinit(&vk.gx),
            .sdl => allocator.free(self.tints),
        }
        self.* = undefined;
    }

    /// Assumes the pos points to the center of the sprite.
    fn toSdlRect(sprite: Sprite, pos: Vec2) c.SDL_Rect {
        const sprite_size = sprite.size();
        return sdlRect(pos.minus(sprite_size.scaled(0.5)), sprite_size);
    }

    fn size(sprite: Sprite) Vec2 {
        return .{
            .x = @floatFromInt(sprite.rect.w),
            .y = @floatFromInt(sprite.rect.h),
        };
    }

    fn radius(sprite: Sprite) f32 {
        const s = sprite.size();
        return (s.x + s.y) / 4.0;
    }
};

// TODO: does this belong as a method on bounded array?
fn boundedArrayFromArray(comptime T: type, comptime capacity: usize, array: anytype) BoundedArray(T, capacity) {
    switch (@typeInfo(@TypeOf(array))) {
        .Array => {},
        else => @compileError("expected array"),
    }
    comptime assert(array.len <= capacity);
    return BoundedArray(T, capacity).fromSlice(&array) catch unreachable;
}

const Game = struct {
    assets: *Assets,

    ease_t: f32 = 0.0,

    controllers: [4]?*c.SDL_GameController = .{ null, null, null, null },
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

    stars: [150]Star,

    particle: Sprite.Index,

    rng: std.Random.DefaultPrng,

    camera: Vec2 = .zero,

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
            .vel = .{ .x = 0, .y = 0 },
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
        thruster.add(cb, TeamIndex, team_index);
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
            .vel = .{ .x = 0, .y = 0 },
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
        thruster.add(cb, TeamIndex, team_index);
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
            .vel = .{ .x = 0, .y = 0 },
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
        thruster.add(cb, TeamIndex, team_index);
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
            .vel = .{ .x = 0, .y = 0 },
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
        thruster.add(cb, TeamIndex, team_index);
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
            .vel = .{ .x = 0, .y = 0 },
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
            thruster.add(cb, Transform, .{ .pos = .{ .x = 100, .y = 0 } });
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
            thruster.add(cb, TeamIndex, team_index);
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
            thruster.add(cb, TeamIndex, team_index);
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
            thruster.add(cb, TeamIndex, team_index);
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
            thruster.add(cb, TeamIndex, team_index);
        }
    }

    fn init(allocator: Allocator, assets: *Assets) !Game {
        const image_zone = Zone.begin(.{ .src = @src() });

        var cb: gpu.CmdBuf = undefined;
        switch (assets.renderer.*) {
            .vk => |*vk| {
                vk.gx.beginFrame();
                cb = .init(&vk.gx, .{
                    .name = "Color Image Upload",
                    .src = @src(),
                });
            },
            .sdl => {},
        }

        const team_tints = &.{
            .{
                16,
                124,
                196,
            },
            .{
                237,
                210,
                64,
            },
            .{
                224,
                64,
                237,
            },
            .{
                83,
                237,
                64,
            },
        };
        const no_tint = &.{};

        const ring_bg = try assets.loadSprite(allocator, cb, "img/ring.png", null, no_tint);
        const star_small = try assets.loadSprite(allocator, cb, "img/star/small.png", null, no_tint);
        const star_large = try assets.loadSprite(allocator, cb, "img/star/large.png", null, no_tint);
        const planet_red = try assets.loadSprite(allocator, cb, "img/planet-red.png", null, no_tint);
        const bullet_small = try assets.loadSprite(allocator, cb, "img/bullet/small.png", null, no_tint);
        const bullet_shiny = try assets.loadSprite(allocator, cb, "img/bullet/shiny.png", null, no_tint);

        var shrapnel_sprites: [shrapnel_sprite_names.len]Sprite.Index = undefined;
        for (&shrapnel_sprites, shrapnel_sprite_names) |*s, name| {
            s.* = try assets.loadSprite(allocator, cb, name, null, no_tint);
        }

        var rock_sprites: [rock_sprite_names.len]Sprite.Index = undefined;
        for (&rock_sprites, rock_sprite_names) |*s, name| {
            s.* = try assets.loadSprite(allocator, cb, name, null, no_tint);
        }

        const shrapnel_animations: [shrapnel_sprites.len]Animation.Index = .{
            try assets.addAnimation(&.{shrapnel_sprites[0]}, null, 30, 0.0),
            try assets.addAnimation(&.{shrapnel_sprites[1]}, null, 30, 0.0),
            try assets.addAnimation(&.{shrapnel_sprites[2]}, null, 30, 0.0),
        };

        const ranger_sprites = .{
            try assets.loadSprite(allocator, cb, "img/ship/ranger/diffuse.png", "img/ship/ranger/recolor.png", team_tints),
            try assets.loadSprite(allocator, cb, "img/ship/ranger/thrusters/0.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/ranger/thrusters/1.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/ranger/thrusters/2.png", null, no_tint),
        };
        const ranger_still = try assets.addAnimation(&.{
            ranger_sprites[0],
        }, null, 30, 0.0);
        const ranger_steady_thrust = try assets.addAnimation(&.{
            ranger_sprites[2],
            ranger_sprites[3],
        }, null, 10, 0.0);
        const ranger_accel = try assets.addAnimation(&.{
            ranger_sprites[1],
        }, ranger_steady_thrust, 10, 0.0);

        const militia_sprites = .{
            try assets.loadSprite(allocator, cb, "img/ship/militia/diffuse.png", "img/ship/militia/recolor.png", team_tints),
            try assets.loadSprite(allocator, cb, "img/ship/militia/thrusters/0.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/militia/thrusters/1.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/militia/thrusters/2.png", null, no_tint),
        };
        const militia_still = try assets.addAnimation(&.{
            militia_sprites[0],
        }, null, 30, 0.0);
        const militia_steady_thrust = try assets.addAnimation(&.{
            militia_sprites[2],
            militia_sprites[3],
        }, null, 10, 0.0);
        const militia_accel = try assets.addAnimation(&.{
            militia_sprites[1],
        }, militia_steady_thrust, 10, 0.0);

        const explosion_animation = try assets.addAnimation(&.{
            try assets.loadSprite(allocator, cb, "img/explosion/01.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/02.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/03.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/04.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/05.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/06.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/07.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/08.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/09.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/10.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/11.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/explosion/12.png", null, no_tint),
        }, .none, 30, 0.0);

        const triangle_sprites = .{
            try assets.loadSprite(allocator, cb, "img/ship/triangle/diffuse.png", "img/ship/triangle/recolor.png", team_tints),
            try assets.loadSprite(allocator, cb, "img/ship/triangle/thrusters/0.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/triangle/thrusters/1.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/triangle/thrusters/2.png", null, no_tint),
        };
        const triangle_still = try assets.addAnimation(&.{
            triangle_sprites[0],
        }, null, 30, 0.0);
        const triangle_steady_thrust = try assets.addAnimation(&.{
            triangle_sprites[2],
            triangle_sprites[3],
        }, null, 10, 0.0);
        const triangle_accel = try assets.addAnimation(&.{
            triangle_sprites[1],
        }, triangle_steady_thrust, 10, 0.0);

        const kevin_sprites = .{
            try assets.loadSprite(allocator, cb, "img/ship/kevin/diffuse.png", "img/ship/kevin/recolor.png", team_tints),
            try assets.loadSprite(allocator, cb, "img/ship/kevin/thrusters/0.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/kevin/thrusters/1.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/kevin/thrusters/2.png", null, no_tint),
        };
        const kevin_still = try assets.addAnimation(&.{
            kevin_sprites[0],
        }, null, 30, 0.0);
        const kevin_steady_thrust = try assets.addAnimation(&.{
            kevin_sprites[2],
            kevin_sprites[3],
        }, null, 10, 0.0);
        const kevin_accel = try assets.addAnimation(&.{
            kevin_sprites[1],
        }, kevin_steady_thrust, 10, 0.0);

        const wendy_sprite = try assets.loadSprite(allocator, cb, "img/ship/wendy/diffuse.png", "img/ship/wendy/recolor.png", team_tints);
        const wendy_thrusters_left = .{
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/left/0.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/left/1.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/left/2.png", null, no_tint),
        };
        const wendy_thrusters_right = .{
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/right/0.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/right/1.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/right/2.png", null, no_tint),
        };
        const wendy_thrusters_top = .{
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/top/0.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/top/1.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/top/2.png", null, no_tint),
        };
        const wendy_thrusters_bottom = .{
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/bottom/0.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/bottom/1.png", null, no_tint),
            try assets.loadSprite(allocator, cb, "img/ship/wendy/thrusters/bottom/2.png", null, no_tint),
        };
        const wendy_still = try assets.addAnimation(&.{
            wendy_sprite,
        }, null, 30, 0.0);
        const wendy_thrusters_left_steady = try assets.addAnimation(&.{
            wendy_thrusters_left[1],
            wendy_thrusters_left[2],
        }, null, 10, 0.0);
        const wendy_thrusters_left_accel = try assets.addAnimation(&.{
            wendy_thrusters_left[0],
        }, wendy_thrusters_left_steady, 10, 0.0);
        const wendy_thrusters_right_steady = try assets.addAnimation(&.{
            wendy_thrusters_right[1],
            wendy_thrusters_right[2],
        }, null, 10, 0.0);
        const wendy_thrusters_right_accel = try assets.addAnimation(&.{
            wendy_thrusters_right[0],
        }, wendy_thrusters_right_steady, 10, 0.0);
        const wendy_thrusters_top_steady = try assets.addAnimation(&.{
            wendy_thrusters_top[1],
            wendy_thrusters_top[2],
        }, null, 10, 0.0);
        const wendy_thrusters_top_accel = try assets.addAnimation(&.{
            wendy_thrusters_top[0],
        }, wendy_thrusters_top_steady, 10, 0.0);
        const wendy_thrusters_bottom_steady = try assets.addAnimation(&.{
            wendy_thrusters_bottom[1],
            wendy_thrusters_bottom[2],
        }, null, 10, 0.0);
        const wendy_thrusters_bottom_accel = try assets.addAnimation(&.{
            wendy_thrusters_bottom[0],
        }, wendy_thrusters_bottom_steady, 10, 0.0);

        const ranger_radius = @as(f32, @floatFromInt(assets.sprite(ranger_sprites[0]).rect.w)) / 2.0;
        const militia_radius = @as(f32, @floatFromInt(assets.sprite(militia_sprites[0]).rect.w)) / 2.0;
        const triangle_radius = @as(f32, @floatFromInt(assets.sprite(triangle_sprites[0]).rect.w)) / 2.0;
        const kevin_radius = @as(f32, @floatFromInt(assets.sprite(triangle_sprites[0]).rect.w)) / 2.0;
        const wendy_radius = @as(f32, @floatFromInt(assets.sprite(triangle_sprites[0]).rect.w)) / 2.0;

        const particle = try assets.loadSprite(allocator, cb, "img/particle.png", null, team_tints);

        const controller_default = input_system.ControlScheme.Controller{
            .turn = .{
                .axis = .{
                    .axis = c.SDL_CONTROLLER_AXIS_LEFTX,
                    .dead_zone = dead_zone,
                },
            },
            .thrust_forward = .{
                .buttons = .{ .positive = c.SDL_CONTROLLER_BUTTON_B },
            },
            .thrust_x = .{
                .axis = .{
                    .axis = c.SDL_CONTROLLER_AXIS_LEFTX,
                    .dead_zone = dead_zone,
                },
            },
            .thrust_y = .{
                .axis = .{
                    .axis = c.SDL_CONTROLLER_AXIS_LEFTY,
                    .dead_zone = dead_zone,
                },
            },
            .fire = .{
                .buttons = .{ .positive = c.SDL_CONTROLLER_BUTTON_A },
            },
            .start = .{
                .buttons = .{ .positive = c.SDL_CONTROLLER_BUTTON_START },
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

        const random_seed: u64 = s: {
            var buf: [8]u8 = undefined;
            std.options.cryptoRandomSeed(&buf);
            break :s @bitCast(buf);
        };

        switch (assets.renderer.*) {
            .vk => |*vk| {
                const zone: Zone = .begin(.{ .name = "Upload Images", .src = @src() });
                defer zone.end();
                cb.submit(&vk.gx);
                vk.upload_queue.reset();
                vk.gx.endFrame(.{ .present = false });
            },
            else => {},
        }
        image_zone.end();

        return .{
            .rng = std.Random.DefaultPrng.init(random_seed),
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
        };
    }

    fn createShip(
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

    fn shipLifeSprite(game: Game, class: Ship.Class) Sprite.Index {
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

    fn animationRadius(game: Game, animation_index: Animation.Index) f32 {
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

    fn setupScenario(game: *Game, es: *Entities, cb: *CmdBuf, scenario: Scenario) void {
        const rng = game.rng.random();
        cb.clear(es); // TODO: if we didn't clear here es could be const

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
            {
                var player_index: u32 = 0;
                for (0..@as(usize, @intCast(c.SDL_NumJoysticks()))) |i_usize| {
                    const i: u31 = @intCast(i_usize);
                    if (c.SDL_IsGameController(i) != c.SDL_FALSE) {
                        const sdl_controller = c.SDL_GameControllerOpen(i) orelse {
                            panic("SDL_GameControllerOpen failed: {s}\n", .{c.SDL_GetError()});
                        };
                        if (c.SDL_GameControllerGetAttached(sdl_controller) != c.SDL_FALSE) {
                            game.controllers[i] = sdl_controller;
                            player_index += 1;
                            if (player_index >= game.controllers.len) break;
                        } else {
                            c.SDL_GameControllerClose(sdl_controller);
                        }
                    }
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
        // XXX: random in circle biased doesn't need to be scaled, audit other calls to this
        for (0..rock_amt) |_| {
            const speed = 20 + rng.float(f32) * 300;
            const radius = 25 + rng.float(f32) * 110;
            const sprite = game.rock_sprites[rng.uintLessThanBiased(usize, game.rock_sprites.len)];
            const pos = randomInCircleBiased(rng, lerp(display_radius, display_radius * 1.1, rng.float(f32)))
                .plus(display_center);

            const e = Entity.reserve(cb);
            e.add(cb, Sprite.Index, sprite);
            e.add(cb, Transform, .{
                .pos = pos,
            });
            e.add(cb, RigidBody, .{
                .vel = randomOnCircle(rng, speed),
                .rotation_vel = lerp(-1.0, 1.0, rng.float(f32)),
                .radius = radius,
                .density = 0.10,
            });
            e.add(cb, Collider, .{
                .collision_damping = 1,
                .layer = .hazard,
            });
        }

        // Create stars
        generateStars(&game.stars, rng);
    }

    fn spawnTeamVictory(game: *Game, cb: *CmdBuf, pos: Vec2, team_index: TeamIndex) void {
        const rng = game.rng.random();
        for (0..500) |_| {
            const random_vel = randomOnCircle(rng, 300);
            const e = Entity.reserve(cb);
            e.add(cb, Lifetime, .{
                .seconds = 1000,
            });
            e.add(cb, Transform, .{
                .pos = pos,
                .rot = .fromAngle(math.tau * rng.float(f32)),
            });
            e.add(cb, RigidBody, .{
                .vel = random_vel,
                .rotation_vel = math.tau * rng.float(f32),
                .radius = 16,
                .density = 0.001,
            });
            e.add(cb, Sprite.Index, game.particle);
            e.add(cb, TeamIndex, team_index);
        }
    }

    fn aliveTeam(game: Game) TeamIndex {
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

    fn over(game: Game) bool {
        return game.aliveTeamCount() <= 1;
    }
};

pub const SpriteGlobal = extern struct {
    world_to_view: Mat2x3 = .identity,
};

const SpriteStorageLayout = BufferLayout(.{
    .kind = .{ .storage = true },
    .frame = &.{
        .{
            .name = "global",
            .size = @sizeOf(SpriteGlobal),
            .alignment = @alignOf(SpriteGlobal),
        },
    },
});

const Assets = struct {
    gpa: Allocator,
    renderer: *Renderer,
    dir: std.fs.Dir,
    sprites: std.ArrayListUnmanaged(Sprite),
    frames: std.ArrayListUnmanaged(Sprite.Index),
    animations: std.ArrayListUnmanaged(Animation),
    sprite_pipeline: gpu.Pipeline,
    sprite_pipeline_layout: gpu.Pipeline.Layout,
    desc_pool: gpu.DescPool,
    sprite_desc_sets: [gpu.global_options.max_frames_in_flight]gpu.DescSet,
    sprite_storage_buffer: gpu.UploadBuf(.{ .storage = true }),
    sprite_storage_layout: SpriteStorageLayout,

    const Frame = struct {
        sprite: Sprite,
        angle: f32,
    };

    fn init(gpa: Allocator, renderer: *Renderer) !Assets {
        const self_exe_dir_path = try std.fs.selfExeDirPathAlloc(gpa);
        defer gpa.free(self_exe_dir_path);
        const assets_dir_path = try std.fs.path.join(gpa, &.{ self_exe_dir_path, "data" });
        defer gpa.free(assets_dir_path);
        const dir = std.fs.openDirAbsolute(assets_dir_path, .{}) catch |err| {
            panic("unable to open assets directory '{s}': {s}", .{
                assets_dir_path, @errorName(err),
            });
        };

        var sprite_pipeline: gpu.Pipeline = undefined;
        var sprite_pipeline_layout: gpu.Pipeline.Layout = undefined;
        var sprite_desc_sets: [gpu.global_options.max_frames_in_flight]gpu.DescSet = undefined;
        var desc_pool: gpu.DescPool = undefined;
        var sprite_storage_layout: SpriteStorageLayout = undefined;
        var sprite_storage_buffer: gpu.UploadBuf(.{ .storage = true }) = undefined;
        switch (renderer.*) {
            .vk => |*vk| {
                const zone = Zone.begin(.{ .name = "create pipelines", .src = @src() });
                defer zone.end();

                const sprite_vert_spv = initSpv(gpa, "data/shaders/sprite.vert.spv");
                defer gpa.free(sprite_vert_spv);
                const sprite_vert_module: gpu.ShaderModule = .init(&vk.gx, .{
                    .name = .{ .str = "sprite.vert.spv" },
                    .ir = sprite_vert_spv,
                });
                defer sprite_vert_module.deinit(&vk.gx);

                const sprite_frag_spv = initSpv(gpa, "data/shaders/sprite.frag.spv");
                defer gpa.free(sprite_frag_spv);
                const sprite_frag_module: gpu.ShaderModule = .init(&vk.gx, .{
                    .name = .{ .str = "sprite.frag.spv" },
                    .ir = sprite_frag_spv,
                });
                defer sprite_frag_module.deinit(&vk.gx);

                const sprite_pipeline_layout_options: gpu.Pipeline.Layout.Options = .{
                    .name = .{ .str = "Pixelate Pipeline" },
                    .descs = &.{
                        .{
                            .name = "camera",
                            .kind = .storage_buffer,
                            .stages = .{ .vertex = true },
                        },
                    },
                };

                sprite_pipeline_layout = .init(&vk.gx, sprite_pipeline_layout_options);

                gpu.Pipeline.initGraphics(&vk.gx, &.{
                    .{
                        .name = .{ .str = "Sprites" },
                        .stages = .{
                            .vertex = sprite_vert_module,
                            .fragment = sprite_frag_module,
                        },
                        .result = &sprite_pipeline,
                        .input_assembly = .{ .triangle_strip = .{} },
                        .layout = sprite_pipeline_layout,
                        .color_attachment_formats = &.{
                            vk.gx.device.surface_format,
                        },
                        .depth_attachment_format = .undefined,
                        .stencil_attachment_format = .undefined,
                    },
                });

                var create_descs: std.BoundedArray(gpu.DescPool.Options.Cmd, sprite_desc_sets.len) = .{};
                for (&sprite_desc_sets, 0..) |*desc_set, i| {
                    create_descs.appendAssumeCapacity(.{
                        .name = .{ .str = "Sprites", .index = i },
                        .result = desc_set,
                        .layout = sprite_pipeline_layout.desc_set,
                        .layout_options = &sprite_pipeline_layout_options,
                    });
                }
                desc_pool = .init(&vk.gx, .{
                    .name = .{ .str = "Game" },
                    .cmds = create_descs.constSlice(),
                });

                sprite_storage_layout = .init(&vk.gx);
                sprite_storage_buffer = .init(&vk.gx, .{
                    .name = .{ .str = "Sprite Storage" },
                    .size = sprite_storage_layout.buffer_size,
                    .prefer_device_local = false,
                });

                var desc_set_updates: std.BoundedArray(
                    gpu.DescSet.Update,
                    sprite_desc_sets.len,
                ) = .{};
                for (sprite_desc_sets, 0..) |set, i| {
                    desc_set_updates.appendAssumeCapacity(.{
                        .set = set,
                        .binding = 0,
                        .value = .{
                            .storage_buf = sprite_storage_layout.frame(@intCast(i)).global.view(sprite_storage_buffer.handle),
                        },
                    });
                }
                gpu.DescSet.update(&vk.gx, desc_set_updates.constSlice());
            },
            .sdl => {},
        }

        return .{
            .gpa = gpa,
            .renderer = renderer,
            .dir = dir,
            .sprites = .{},
            .frames = .{},
            .animations = .{},
            .sprite_pipeline = sprite_pipeline,
            .sprite_pipeline_layout = sprite_pipeline_layout,
            .desc_pool = desc_pool,
            .sprite_desc_sets = sprite_desc_sets,
            .sprite_storage_layout = sprite_storage_layout,
            .sprite_storage_buffer = sprite_storage_buffer,
        };
    }

    fn initSpv(gpa: Allocator, path: []const u8) []const u32 {
        const max_bytes = 80192;
        const size_hint = 4096;
        const spv = std.fs.cwd().readFileAllocOptions(
            gpa,
            path,
            max_bytes,
            size_hint,
            .of(u32),
            null,
        ) catch |err| std.debug.panic("{s}: {}", .{ path, err });
        var u32s: []const u32 = undefined;
        u32s.ptr = @ptrCast(spv.ptr);
        u32s.len = spv.len / 4;
        return u32s;
    }

    fn deinit(a: *Assets) void {
        a.dir.close();
        for (a.sprites.items) |*s| {
            s.deinit(a.gpa, a.renderer);
        }
        a.sprites.deinit(a.gpa);
        a.frames.deinit(a.gpa);
        a.animations.deinit(a.gpa);
        switch (a.renderer.*) {
            .vk => |*vk| {
                vk.gx.waitIdle();
                a.sprite_pipeline_layout.deinit(&vk.gx);
                a.sprite_pipeline.deinit(&vk.gx);
                a.desc_pool.deinit(&vk.gx);
                a.sprite_storage_buffer.deinit(&vk.gx);
            },
            .sdl => {},
        }
        a.* = undefined;
    }

    fn animate(a: Assets, anim: *Animation.Playback, delta_s: f32) Frame {
        const animation = a.animations.items[@intFromEnum(anim.index)];
        const frame_index: u32 = @intFromFloat(@floor(anim.time_passed * animation.fps));
        const frame = animation.start + frame_index;
        // TODO: for large delta_s can cause out of bounds index
        const frame_sprite = a.sprite(a.frames.items[frame]);
        anim.time_passed += delta_s;
        const end_time = @as(f32, @floatFromInt(animation.len)) / animation.fps;
        if (anim.time_passed >= end_time) {
            anim.time_passed -= end_time;
            anim.index = animation.next;
        }
        return .{
            .sprite = frame_sprite,
            .angle = animation.angle,
        };
    }

    /// null next_animation means to loop.
    fn addAnimation(
        a: *Assets,
        frames: []const Sprite.Index,
        next_animation: ?Animation.Index,
        fps: f32,
        angle: f32,
    ) !Animation.Index {
        try a.frames.appendSlice(a.gpa, frames);
        const result: Animation.Index = @enumFromInt(a.animations.items.len);
        try a.animations.append(a.gpa, .{
            .start = @intCast(a.frames.items.len - frames.len),
            .len = @intCast(frames.len),
            .next = next_animation orelse result,
            .fps = fps,
            .angle = angle,
        });
        return result;
    }

    fn sprite(a: Assets, index: Sprite.Index) Sprite {
        return a.sprites.items[@intFromEnum(index)];
    }

    fn loadSprite(a: *Assets, allocator: Allocator, cb: gpu.CmdBuf, diffuse_name: [:0]const u8, recolor_name: ?[:0]const u8, tints: []const [3]u8) !Sprite.Index {
        switch (a.renderer.*) {
            .sdl => |sdl| {
                const diffuse_png = try a.dir.readFileAlloc(a.gpa, diffuse_name, 50 * 1024 * 1024);
                defer a.gpa.free(diffuse_png);
                const recolor = if (recolor_name != null) try a.dir.readFileAlloc(a.gpa, recolor_name.?, 50 * 1024 * 1024) else null;
                defer if (recolor != null) a.gpa.free(recolor.?);
                try a.sprites.append(a.gpa, try spriteFromBytes(allocator, diffuse_png, recolor, sdl, tints));
                return @as(Sprite.Index, @enumFromInt(a.sprites.items.len - 1));
            },
            .vk => |*vk| {
                const diffuse_png = try a.dir.readFileAlloc(a.gpa, diffuse_name, 50 * 1024 * 1024);
                defer a.gpa.free(diffuse_png);

                var width: c_int = undefined;
                var height: c_int = undefined;
                const channel_count = 4;
                const c_pixels = c.stbi_load_from_memory(
                    diffuse_png.ptr,
                    @intCast(diffuse_png.len),
                    &width,
                    &height,
                    null,
                    channel_count,
                );
                defer c.stbi_image_free(c_pixels);
                const pixels = c_pixels[0..@intCast(width * height * channel_count)];

                const image = vk.upload_queue.beginWrite(&vk.gx, cb, .{
                    .name = .{ .str = diffuse_name },
                    .alloc = .{ .auto = .{
                        .memory = vk.color_images,
                        .offset = &vk.upload_offset,
                    } },
                    .image = .{
                        .format = .r8g8b8a8_srgb,
                        .extent = .{
                            .width = @intCast(width),
                            .height = @intCast(height),
                            .depth = 1,
                        },
                        .usage = .{
                            .transfer_dst = true,
                            .sampled = true,
                        },
                    },
                }) catch |err| @panic(@errorName(err));

                vk.upload_queue.writer.writeAll(pixels) catch |err| @panic(@errorName(err));

                try a.sprites.append(a.gpa, .{
                    .tints = &.{},
                    .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
                    .image = image,
                });
                return @as(Sprite.Index, @enumFromInt(a.sprites.items.len - 1));
            },
        }
    }

    fn spriteFromBytesVk(
        allocator: Allocator,
        png_diffuse: []const u8,
        png_recolor: ?[]const u8,
        renderer: *c.SDL_Renderer,
        tints: []const [3]u8,
    ) !Sprite {
        var width: c_int = undefined;
        var height: c_int = undefined;
        const channel_count = 4;
        const bits_per_channel = 8;
        const diffuse_data = c.stbi_load_from_memory(
            png_diffuse.ptr,
            @intCast(png_diffuse.len),
            &width,
            &height,
            null,
            channel_count,
        );
        defer c.stbi_image_free(diffuse_data);
        var recolor_width: c_int = undefined;
        var recolor_height: c_int = undefined;
        const recolor_data = if (png_recolor != null) c.stbi_load_from_memory(
            png_recolor.?.ptr,
            @intCast(png_recolor.?.len),
            &recolor_width,
            &recolor_height,
            null,
            1,
        ) else null;
        defer if (recolor_data != null) c.stbi_image_free(recolor_data.?);
        if (recolor_data != null) {
            assert(width == recolor_width and height == recolor_height);
        }

        var textures = try ArrayListUnmanaged(*c.SDL_Texture).initCapacity(allocator, tints.len);
        defer textures.deinit(allocator);
        for (tints) |tint| {
            const diffuse_copy = try allocator.alloc(u8, @intCast(width * height * channel_count));
            defer allocator.free(diffuse_copy);
            @memcpy(diffuse_copy, diffuse_data[0..diffuse_copy.len]);

            for (0..diffuse_copy.len / channel_count) |pixel| {
                const r = &diffuse_copy[pixel * channel_count];
                const g = &diffuse_copy[pixel * channel_count + 1];
                const b = &diffuse_copy[pixel * channel_count + 2];

                var color: [3]f32 = .{
                    @as(f32, @floatFromInt(r.*)) / 255.0,
                    @as(f32, @floatFromInt(g.*)) / 255.0,
                    @as(f32, @floatFromInt(b.*)) / 255.0,
                };

                // Change gamma
                const gamma = 2.2;
                for (&color) |*color_channel| {
                    color_channel.* = math.pow(f32, color_channel.*, 1.0 / gamma);
                }

                // Convert to grayscale or determine recolor amount
                var amount: f32 = 1.0;
                if (recolor_data) |recolor| {
                    amount = @as(f32, @floatFromInt(recolor[pixel])) / 255.0;
                } else {
                    var luminosity = 0.299 * color[0] + 0.587 * color[1] + 0.0722 * color[2] / 255.0;
                    luminosity = math.pow(f32, luminosity, 1.0 / gamma);
                    for (&color) |*color_channel| {
                        color_channel.* = luminosity;
                    }
                }

                // Apply tint
                for (&color, tint) |*color_channel, tint_channel| {
                    const recolored = math.pow(f32, @as(f32, @floatFromInt(tint_channel)) / 255.0, 1.0 / gamma);
                    color_channel.* = lerp(color_channel.*, color_channel.* * recolored, amount);
                }

                // Change gamma back
                for (&color) |*color_channel| {
                    color_channel.* = math.pow(f32, color_channel.*, gamma);
                }

                // Apply changes
                r.* = @intFromFloat(color[0] * 255.0);
                g.* = @intFromFloat(color[1] * 255.0);
                b.* = @intFromFloat(color[2] * 255.0);
            }
            const pitch = width * channel_count;
            const surface = c.SDL_CreateRGBSurfaceFrom(
                diffuse_copy.ptr,
                width,
                height,
                channel_count * bits_per_channel,
                pitch,
                0x000000ff,
                0x0000ff00,
                0x00ff0000,
                0xff000000,
            );
            defer c.SDL_FreeSurface(surface);
            textures.appendAssumeCapacity(c.SDL_CreateTextureFromSurface(renderer, surface) orelse
                panic("unable to convert surface to texture", .{}));
        } else {
            const pitch = width * channel_count;
            const surface = c.SDL_CreateRGBSurfaceFrom(
                diffuse_data,
                width,
                height,
                channel_count * bits_per_channel,
                pitch,
                0x000000ff,
                0x0000ff00,
                0x00ff0000,
                0xff000000,
            );
            defer c.SDL_FreeSurface(surface);
            try textures.append(allocator, c.SDL_CreateTextureFromSurface(renderer, surface) orelse
                panic("unable to convert surface to texture", .{}));
        }
        return .{
            .tints = try textures.toOwnedSlice(allocator),
            .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        };
    }

    fn spriteFromBytes(
        allocator: Allocator,
        png_diffuse: []const u8,
        png_recolor: ?[]const u8,
        renderer: *c.SDL_Renderer,
        tints: []const [3]u8,
    ) !Sprite {
        var width: c_int = undefined;
        var height: c_int = undefined;
        const channel_count = 4;
        const bits_per_channel = 8;
        const diffuse_data = c.stbi_load_from_memory(
            png_diffuse.ptr,
            @intCast(png_diffuse.len),
            &width,
            &height,
            null,
            channel_count,
        );
        defer c.stbi_image_free(diffuse_data);
        var recolor_width: c_int = undefined;
        var recolor_height: c_int = undefined;
        const recolor_data = if (png_recolor != null) c.stbi_load_from_memory(
            png_recolor.?.ptr,
            @intCast(png_recolor.?.len),
            &recolor_width,
            &recolor_height,
            null,
            1,
        ) else null;
        defer if (recolor_data != null) c.stbi_image_free(recolor_data.?);
        if (recolor_data != null) {
            assert(width == recolor_width and height == recolor_height);
        }

        var textures = try ArrayListUnmanaged(*c.SDL_Texture).initCapacity(allocator, tints.len);
        defer textures.deinit(allocator);
        for (tints) |tint| {
            const diffuse_copy = try allocator.alloc(u8, @intCast(width * height * channel_count));
            defer allocator.free(diffuse_copy);
            @memcpy(diffuse_copy, diffuse_data[0..diffuse_copy.len]);

            for (0..diffuse_copy.len / channel_count) |pixel| {
                const r = &diffuse_copy[pixel * channel_count];
                const g = &diffuse_copy[pixel * channel_count + 1];
                const b = &diffuse_copy[pixel * channel_count + 2];

                var color: [3]f32 = .{
                    @as(f32, @floatFromInt(r.*)) / 255.0,
                    @as(f32, @floatFromInt(g.*)) / 255.0,
                    @as(f32, @floatFromInt(b.*)) / 255.0,
                };

                // Change gamma
                const gamma = 2.2;
                for (&color) |*color_channel| {
                    color_channel.* = math.pow(f32, color_channel.*, 1.0 / gamma);
                }

                // Convert to grayscale or determine recolor amount
                var amount: f32 = 1.0;
                if (recolor_data) |recolor| {
                    amount = @as(f32, @floatFromInt(recolor[pixel])) / 255.0;
                } else {
                    var luminosity = 0.299 * color[0] + 0.587 * color[1] + 0.0722 * color[2] / 255.0;
                    luminosity = math.pow(f32, luminosity, 1.0 / gamma);
                    for (&color) |*color_channel| {
                        color_channel.* = luminosity;
                    }
                }

                // Apply tint
                for (&color, tint) |*color_channel, tint_channel| {
                    const recolored = math.pow(f32, @as(f32, @floatFromInt(tint_channel)) / 255.0, 1.0 / gamma);
                    color_channel.* = lerp(color_channel.*, color_channel.* * recolored, amount);
                }

                // Change gamma back
                for (&color) |*color_channel| {
                    color_channel.* = math.pow(f32, color_channel.*, gamma);
                }

                // Apply changes
                r.* = @intFromFloat(color[0] * 255.0);
                g.* = @intFromFloat(color[1] * 255.0);
                b.* = @intFromFloat(color[2] * 255.0);
            }
            const pitch = width * channel_count;
            const surface = c.SDL_CreateRGBSurfaceFrom(
                diffuse_copy.ptr,
                width,
                height,
                channel_count * bits_per_channel,
                pitch,
                0x000000ff,
                0x0000ff00,
                0x00ff0000,
                0xff000000,
            );
            defer c.SDL_FreeSurface(surface);
            textures.appendAssumeCapacity(c.SDL_CreateTextureFromSurface(renderer, surface) orelse
                panic("unable to convert surface to texture", .{}));
        } else {
            const pitch = width * channel_count;
            const surface = c.SDL_CreateRGBSurfaceFrom(
                diffuse_data,
                width,
                height,
                channel_count * bits_per_channel,
                pitch,
                0x000000ff,
                0x0000ff00,
                0x00ff0000,
                0xff000000,
            );
            defer c.SDL_FreeSurface(surface);
            try textures.append(allocator, c.SDL_CreateTextureFromSurface(renderer, surface) orelse
                panic("unable to convert surface to texture", .{}));
        }
        return .{
            .tints = try textures.toOwnedSlice(allocator),
            .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
            .image = null,
        };
    }
};

const Star = struct {
    x: i32,
    y: i32,
    kind: Kind,

    const Kind = enum { large, small, planet_red };
};

fn generateStars(stars: []Star, rng: std.Random) void {
    for (stars) |*star| {
        star.* = .{
            .x = rng.uintLessThanBiased(u31, display_width),
            .y = rng.uintLessThanBiased(u31, display_height),
            .kind = @enumFromInt(rng.uintLessThanBiased(u8, 2)),
        };
    }
    // Overwrite the last one so it shows up on top
    stars[stars.len - 1].kind = .planet_red;
}

/// In this game we use (1, 0) as the 0-rotation vector.
/// In other words, 0 radians means pointing directly to the right.
/// (PI / 2) radians means (0, 1), or pointing directly down to the bottom of the screen.
/// SDL uses degrees (🤮), but at least it also uses clockwise rotation.
fn toDegrees(radians: f32) f32 {
    return 360.0 * (radians / (math.tau));
}

fn sdlRect(top_left_pos: Vec2, size: Vec2) c.SDL_Rect {
    const pos = top_left_pos.floored();
    const size_floored = size.floored();
    return .{
        .x = @intFromFloat(pos.x),
        .y = @intFromFloat(pos.y),
        .w = @intFromFloat(size_floored.x),
        .h = @intFromFloat(size_floored.y),
    };
}

const RenderCopyOptions = struct {
    renderer: *c.SDL_Renderer,
    tex: *c.SDL_Texture,
    rad: f32 = 0.0,
    pos: Vec2,
    size: Vec2,
};
fn renderCopy(opt: RenderCopyOptions) void {
    const pos: Vec2 = .{
        .x = opt.pos.x,
        .y = display_height - opt.pos.y,
    };
    var rect = sdlRect(pos.minus(opt.size.scaled(0.5)), opt.size);
    sdlAssertZero(c.SDL_RenderCopyEx(
        opt.renderer,
        opt.tex,
        null,
        &rect,
        toDegrees(opt.rad),
        null,
        c.SDL_FLIP_NONE,
    ));
}

fn createVulkanSurface(
    instance: VkBackend.vk.Instance,
    context: ?*anyopaque,
    allocation_callbacks: ?*const VkBackend.vk.AllocationCallbacks,
) VkBackend.vk.SurfaceKHR {
    assert(allocation_callbacks == null);
    const screen: *c.SDL_Window = @ptrCast(@alignCast(context));
    var surface: c.VkSurfaceKHR = undefined;
    if (c.SDL_Vulkan_CreateSurface(
        screen,
        @ptrFromInt(@intFromEnum(instance)),
        &surface,
    ) != c.SDL_TRUE) {
        return .null_handle;
    }
    return @enumFromInt(@intFromPtr(surface));
}

test {
    _ = @import("symmetric_matrix.zig");
}
