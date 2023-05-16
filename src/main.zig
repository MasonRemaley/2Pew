const std = @import("std");
const c = @import("c.zig");
const panic = std.debug.panic;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const math = std.math;
const assert = std.debug.assert;
const V = @import("Vec2d.zig");
const ecs = @import("ecs/index.zig");
const FieldEnum = std.meta.FieldEnum;
const MinimumAlignmentAllocator = @import("minimum_alignment_allocator.zig").MinimumAlignmentAllocator;
const SymmetricMatrix = @import("symmetric_matrix.zig").SymmetricMatrix;

const input_system = @import("input_system.zig").init(enum {
    turn,
    thrust_forward,
    thrust_x,
    thrust_y,
    fire,
});

const display_width = 1920;
const display_height = 1080;
const display_center: V = .{
    .x = display_width / 2.0,
    .y = display_height / 2.0,
};
const display_radius = display_height / 2.0;

const Entities = ecs.entities.Entities(.{
    .parent = ?EntityHandle,
    .damage = Damage,
    .animate_on_input = AnimateOnInput,
    .ship = Ship,
    .transform = Transform,
    .rb = RigidBody,
    .player_index = u2,
    .team_index = u2,
    .lifetime = Lifetime,
    .sprite_renderer = SpriteId,
    .animation_player = Animation,
    .collider = Collider,
    .turret = Turret,
    .grapple_gun = GrappleGun,
    .health = Health,
    .spring = Spring,
    .hook = Hook,
    .front_shield = struct {},
});
const PrefabEntity = Entities.PrefabEntity;
const CommandBuffer = ecs.command_buffer.CommandBuffer(Entities);
const EntityHandle = ecs.entities.Handle;
const DeferredHandle = ecs.command_buffer.DeferredHandle;
const ComponentFlags = Entities.ComponentFlags;
const parenting = ecs.parenting.init(Entities).?;
const prefabs = ecs.prefabs.init(Entities);
const PrefabHandle = prefabs.Handle;

const dead_zone = 10000;

const asset_index = @import("asset_index.zig");
const SpriteId = asset_index.sprites.Id;
const AnimationId = asset_index.animations.Id;

// This turns off vsync and logs the frame times to the console. Even better would be debug text on
// screen including this, the number of live entities, etc. We also want warnings/errors to show up
// on screen so we see them immediately when they happen (as well as being logged to the console and
// to a file.)
const profile = false;

pub fn main() !void {
    const gpa = std.heap.c_allocator;

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

    const renderer_flags: u32 = if (profile) 0 else c.SDL_RENDERER_PRESENTVSYNC;
    const sdl_renderer: *c.SDL_Renderer = c.SDL_CreateRenderer(screen, -1, renderer_flags) orelse {
        panic("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyRenderer(sdl_renderer);

    var renderer = try Renderer.init(gpa, sdl_renderer);
    defer renderer.deinit();

    var game = try Game.init();

    // Create initial entities
    var pa = std.heap.page_allocator;
    var buffer = try pa.alloc(u8, ecs.entities.max_entities * 1024);
    defer pa.free(buffer);
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    var maa = MinimumAlignmentAllocator(64).init(fba.allocator());
    const allocator = maa.allocator();
    var entities = try Entities.init(allocator);
    defer entities.deinit();

    var command_buffer = try CommandBuffer.init(allocator, &entities, .{
        .prefab_entity_capacity = 8192,
        .prefab_capacity = 8192,
        .remove_capacity = 8192,
        .arch_change_capacity = 8192,
    });
    defer command_buffer.deinit(allocator);

    game.setupScenario(&command_buffer, .deathmatch_2v2);

    // Run sim
    var delta_s: f32 = 1.0 / 60.0;
    var timer = try std.time.Timer.start();

    // We can use `fx_loop_s` as a time parameter for looping effects without needing extra
    // state everywhere. We loop it at 1000 so that we don't lose precision as the game runs, 1000
    // was chosen so that so long as our effect frequency per second can be any number with three or
    // less digits after the decimal and still loop seemlessly when we reset back to zero.
    var fx_loop_s: f32 = 0.0;
    const max_fx_loop_s: f32 = 1000.0;
    var warned_memory_usage = false;

    while (true) {
        if (poll(&entities, &command_buffer, &game)) return;
        update(&entities, &command_buffer, &game, delta_s);
        render(&renderer, &entities, game, delta_s, fx_loop_s);

        // TODO(mason): we also want a min frame time so we don't get surprising floating point
        // results if it's too close to zero!
        // Adjust our expectd delta time a little every frame. We cap it at `max_frame_time` to
        // prevent e.g. a slow alt tab from messing things up too much.
        const delta_rwa_bias = 0.05;
        const max_frame_time = 1.0 / 30.0;
        const t: f32 = @floatFromInt(timer.lap());
        var last_delta_s = t / std.time.ns_per_s;
        delta_s = lerp(delta_s, @min(last_delta_s, max_frame_time), delta_rwa_bias);
        fx_loop_s = @mod(fx_loop_s + delta_s, max_fx_loop_s);
        if (profile) {
            std.debug.print("frame time: {d}ms ", .{last_delta_s * 1000.0});
            std.debug.print("entity memory: {}/{}mb ", .{ fba.end_index / (1024 * 1024), fba.buffer.len / (1024 * 1024) });
            std.debug.print("\n", .{});
        }

        if (fba.end_index >= fba.buffer.len / 4 and !warned_memory_usage) {
            std.log.warn(">= 25% of entity memory has been used, consider increasing the size of the fixed buffer allocator", .{});
            warned_memory_usage = true;
        }
    }
}

fn poll(entities: *Entities, command_buffer: *CommandBuffer, game: *Game) bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        switch (event.type) {
            c.SDL_QUIT => return true,
            c.SDL_KEYDOWN => switch (event.key.keysym.scancode) {
                c.SDL_SCANCODE_ESCAPE => return true,
                c.SDL_SCANCODE_RETURN => {
                    // Clear invulnerability so you don't have to wait when testing
                    var it = entities.iterator(.{ .health = .{ .mutable = true } });
                    while (it.next()) |entity| {
                        entity.health.invulnerable_s = 0.0;
                    }
                },
                c.SDL_SCANCODE_1 => {
                    game.setupScenario(command_buffer, .deathmatch_2v2);
                },
                c.SDL_SCANCODE_2 => {
                    game.setupScenario(command_buffer, .deathmatch_2v2_no_rocks);
                },
                c.SDL_SCANCODE_3 => {
                    game.setupScenario(command_buffer, .deathmatch_2v2_one_rock);
                },
                c.SDL_SCANCODE_4 => {
                    game.setupScenario(command_buffer, .deathmatch_1v1);
                },
                c.SDL_SCANCODE_5 => {
                    game.setupScenario(command_buffer, .deathmatch_1v1_one_rock);
                },
                c.SDL_SCANCODE_6 => {
                    game.setupScenario(command_buffer, .royale_4p);
                },
                else => {},
            },
            else => {},
        }
    }
    return false;
}

fn update(
    entities: *Entities,
    command_buffer: *CommandBuffer,
    game: *Game,
    delta_s: f32,
) void {
    // Update input
    {
        for (&game.input_state, &game.control_schemes) |*input_state, *control_scheme| {
            input_state.update();
            input_state.applyControlScheme(control_scheme, &game.controllers);
        }
    }

    // Prevent invulnerable entities from firing
    {
        var it = entities.iterator(.{
            .player_index = .{},
            .health = .{},
        });
        while (it.next()) |entity| {
            if (entity.health.invulnerable_s > 0.0) {
                var input_state = &game.input_state[entity.player_index.*];
                input_state.setAction(.fire, .positive, .inactive);
            }
        }
    }

    // Bonk
    {
        var it = entities.iterator(.{
            .rb = .{ .mutable = true },
            .transform = .{},
            .collider = .{},
            .health = .{ .mutable = true, .optional = true },
            .front_shield = .{ .optional = true },
            .hook = .{ .optional = true },
        });
        while (it.next()) |entity| {
            var other_it = it;
            while (other_it.next()) |other| {
                if (!Collider.interacts.get(entity.collider.layer, other.collider.layer)) continue;

                const added_radii = entity.rb.radius + other.rb.radius;
                if (entity.transform.pos.distanceSqrd(other.transform.pos) > added_radii * added_radii) continue;

                // calculate normal
                const normal = other.transform.pos.minus(entity.transform.pos).normalized();
                // calculate relative velocity
                const rv = other.rb.vel.minus(entity.rb.vel);
                // calculate relative velocity in terms of the normal direction
                const vel_along_normal = rv.dot(normal);
                // do not resolve if velocities are separating
                if (vel_along_normal > 0) continue;
                // calculate restitution
                const e = @min(entity.collider.collision_damping, other.collider.collision_damping);
                // calculate impulse scalar
                var j: f32 = -(1.0 + e) * vel_along_normal;
                const my_mass = entity.rb.mass();
                const other_mass = other.rb.mass();
                j /= 1.0 / my_mass + 1.0 / other_mass;
                // apply impulse
                const impulse_mag = normal.scaled(j);
                const impulse = impulse_mag.scaled(1 / my_mass);
                const other_impulse = impulse_mag.scaled(1 / other_mass);
                entity.rb.vel.sub(impulse);
                other.rb.vel.add(other_impulse);

                // Deal HP damage relative to the change in velocity.
                // A very gentle bonk is something like impulse 20, while a
                // very hard bonk is around 300.
                // The basic ranger ship has 80 HP.
                var total_damage: f32 = 0;
                const max_shield = 1.0;
                if (entity.health) |entity_health| {
                    if (other.health == null or other.health.?.invulnerable_s <= 0.0) {
                        var shield_scale: f32 = 0.0;
                        if (entity.front_shield != null) {
                            var dot = V.unit(entity.transform.angle).dot(normal);
                            shield_scale = @max(dot, 0.0);
                        }
                        const damage = lerp(1.0, 1.0 - max_shield, std.math.pow(f32, shield_scale, 1.0 / 2.0)) * remap(20, 300, 0, 80, impulse.length());
                        if (damage >= 2) {
                            total_damage += entity_health.damage(damage);
                        }
                    }
                }
                if (other.health) |other_health| {
                    if (entity.health == null or entity.health.?.invulnerable_s <= 0.0) {
                        var shield_scale: f32 = 0.0;
                        if (other.front_shield != null) {
                            var dot = V.unit(other.transform.angle).dot(normal);
                            shield_scale = @max(-dot, 0.0);
                        }
                        const damage = lerp(1.0, 1.0 - max_shield, std.math.pow(f32, shield_scale, 1.0 / 2.0)) * remap(20, 300, 0, 80, other_impulse.length());
                        if (damage >= 2) {
                            total_damage += other_health.damage(damage);
                        }
                    }
                }

                const shrapnel_amt: u32 = @intFromFloat(
                    @floor(remap_clamped(0, 100, 0, 30, total_damage)),
                );
                const shrapnel_center = entity.transform.pos.plus(other.transform.pos).scaled(0.5);
                const avg_vel = entity.rb.vel.plus(other.rb.vel).scaled(0.5);
                for (0..shrapnel_amt) |_| {
                    // Spawn slightly off center from collision point.
                    const random_offset = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                        .scaled(std.crypto.random.float(f32) * 10);
                    const pos = shrapnel_center.plus(random_offset);

                    // Give them random velocities.
                    const base_vel = if (std.crypto.random.boolean()) entity.rb.vel else other.rb.vel;
                    const random_vel = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                        .scaled(std.crypto.random.float(f32) * base_vel.length() * 2);
                    const vel = avg_vel.plus(random_vel);

                    _ = Game.createShrapnel(command_buffer, pos, vel);
                }

                // TODO: why does it fly away when attached? well partly it's that i set the distance to 0 when
                // the current distance is greater...fixing that
                // TODO: don't always attach to the center? this is easy to do, but, it won't cause
                // rotation the way you'd expect at the moment since the current physics system doesn't
                // have opinions on rotation. We can add that though!
                {
                    var hooked = false;
                    if (entity.hook) |hook| {
                        command_buffer.appendArchChange(it.handle(), .{
                            .add = .{
                                .spring = Spring{
                                    .start = it.handle(),
                                    .end = other_it.handle(),
                                    .k = hook.k,
                                    .length = entity.transform.pos.distance(other.transform.pos),
                                    .damping = hook.damping,
                                },
                            },
                            .remove = ComponentFlags.init(.{.hook}),
                        });
                        hooked = true;
                    }
                    if (other.hook) |hook| {
                        command_buffer.appendArchChange(other_it.handle(), .{
                            .add = .{
                                .spring = Spring{
                                    .start = it.handle(),
                                    .end = other_it.handle(),
                                    .k = hook.k,
                                    .length = entity.transform.pos.distance(other.transform.pos),
                                    .damping = hook.damping,
                                },
                            },
                            .remove = ComponentFlags.init(.{.hook}),
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

    // Update rbs
    {
        var it = entities.iterator(.{
            .rb = .{ .mutable = true },
            .transform = .{ .mutable = true },
            .health = .{ .mutable = true, .optional = true },
        });
        while (it.next()) |entity| {
            entity.transform.pos.add(entity.rb.vel.scaled(delta_s));

            // gravity if the rb is outside the ring
            if (entity.transform.pos.distanceSqrd(display_center) > display_radius * display_radius and entity.rb.density < std.math.inf(f32)) {
                const gravity = 500;
                const gravity_v = display_center.minus(entity.transform.pos).normalized().scaled(gravity * delta_s);
                entity.rb.vel.add(gravity_v);
                if (entity.health) |health| {
                    // punishment for leaving the circle
                    _ = health.damage(delta_s * 4);
                }
            }

            entity.transform.angle = @mod(
                entity.transform.angle + entity.rb.rotation_vel * delta_s,
                2 * math.pi,
            );
        }
    }

    // Update springs
    // {
    //     var it = entities.iterator(.{ .spring = .{} });
    //     while (it.next()) |entity| {
    //         // TODO: crashes if either end has been deleted right now. we may wanna actually make
    //         // checking if an entity is valid or not a feature if there's not a bette way to handle this?
    //         var start_trans = entities.getComponent(entity.spring.start, .transform) orelse {
    //             std.log.err("spring connections require transform, destroying spring entity", .{});
    //             it.swapRemove();
    //             continue;
    //         };

    //         var end_trans = entities.getComponent(entity.spring.end, .transform) orelse {
    //             std.log.err("spring connections require transform, destroying spring entity", .{});
    //             it.swapRemove();
    //             continue;
    //         };
    //         var start_rb = entities.getComponent(entity.spring.start, .rb) orelse {
    //             std.log.err("spring connections require rb, destroying spring entity", .{});
    //             it.swapRemove();
    //             continue;
    //         };

    //         var end_rb = entities.getComponent(entity.spring.end, .rb) orelse {
    //             std.log.err("spring connections require rb, destroying spring entity", .{});
    //             it.swapRemove();
    //             continue;
    //         };

    //         var delta = end_trans.pos.minus(start_trans.pos);
    //         const dir = delta.normalized();

    //         // TODO: min length 0 right now, could make min and max (before force) settable though?
    //         // const x = delta.length() - spring.length;
    //         const x = @max(delta.length() - entity.spring.length, 0.0);
    //         const spring_force = entity.spring.k * x;

    //         const relative_vel = end_rb.vel.dot(dir) - start_rb.vel.dot(dir);
    //         const start_b = @sqrt(entity.spring.damping * 4.0 * start_rb.mass() * entity.spring.k);
    //         const start_damping_force = start_b * relative_vel;
    //         const end_b = @sqrt(entity.spring.damping * 4.0 * end_rb.mass() * entity.spring.k);
    //         const end_damping_force = end_b * relative_vel;

    //         const start_impulse = (start_damping_force + spring_force) * delta_s;
    //         const end_impulse = (end_damping_force + spring_force) * delta_s;
    //         start_rb.vel.add(dir.scaled(start_impulse / start_rb.mass()));
    //         end_rb.vel.add(dir.scaled(-end_impulse / start_rb.mass()));
    //     }
    // }

    // Update entities that do damage
    {
        // TODO(mason): hard to keep the components straight, make shorter handles names and get rid of comps
        var damage_it = entities.iterator(.{
            .damage = .{},
            .rb = .{},
            .transform = .{ .mutable = true },
        });
        while (damage_it.next()) |damage_entity| {
            var health_it = entities.iterator(.{
                .health = .{ .mutable = true },
                .rb = .{},
                .transform = .{},
            });
            while (health_it.next()) |health_entity| {
                if (health_entity.transform.pos.distanceSqrd(damage_entity.transform.pos) <
                    health_entity.rb.radius * health_entity.rb.radius + damage_entity.rb.radius * damage_entity.rb.radius)
                {
                    if (health_entity.health.damage(damage_entity.damage.hp) > 0.0) {
                        const random_vector = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                            .scaled(damage_entity.rb.vel.length() * 0.2);
                        const vel = health_entity.rb.vel.plus(damage_entity.rb.vel.scaled(0.2)).plus(random_vector);
                        _ = Game.createShrapnel(command_buffer, health_entity.transform.pos, vel);
                        command_buffer.appendRemove(damage_it.handle());
                    }
                }
            }

            damage_entity.transform.angle = damage_entity.rb.vel.angle() + math.pi / 2.0;
        }
    }

    // TODO(mason): take velocity from before impact? i may have messed that up somehow
    // Explode things that reach 0 hp
    {
        var it = entities.iterator(.{
            .health = .{ .mutable = true },
            .rb = .{ .optional = true },
            .transform = .{ .optional = true },
            .player_index = .{ .optional = true },
            .team_index = .{ .optional = true },
        });
        while (it.next()) |entity| {
            if (entity.health.hp <= 0) {
                // spawn explosion here
                if (entity.transform) |trans| {
                    _ = command_buffer.appendInstantiate(true, &.{
                        .{
                            .lifetime = .{
                                .seconds = 100,
                            },
                            .transform = .{
                                .pos = trans.pos,
                            },
                            .rb = .{
                                .vel = if (entity.rb) |rb| rb.vel else V{ .x = 0, .y = 0 },
                                .rotation_vel = 0,
                                .radius = 32,
                                .density = 0.001,
                            },
                            .animation_player = .{
                                .id = .explosion,
                                .destroys_entity = true,
                            },
                        },
                    });
                }

                // If this is a player controlled ship, spawn a new ship for the player using this
                // ship's input before we destroy it!
                if (entity.player_index) |player_index| {
                    if (entity.team_index) |team_index| {
                        // give player their next ship
                        const team = &game.teams[team_index.*];
                        if (team.ship_progression_index >= team.ship_progression.len) {
                            const already_over = game.over();
                            team.players_alive -= 1;
                            if (game.over() and !already_over) {
                                const happy_team = game.aliveTeam();
                                Game.spawnTeamVictory(entities, display_center, happy_team);
                            }
                        } else {
                            const new_angle = math.pi * 2 * std.crypto.random.float(f32);
                            const new_pos = display_center.plus(V.unit(new_angle).scaled(display_radius));
                            const facing_angle = new_angle + math.pi;
                            _ = game.createShip(command_buffer, player_index.*, team_index.*, new_pos, facing_angle);
                        }
                    }
                }

                // Destroy the entity
                command_buffer.appendRemove(it.handle());
            }

            // Regen health
            var max_regen = entity.health.regen_ratio * entity.health.max_hp;
            var regen_speed = max_regen / entity.health.regen_s;
            if (entity.health.regen_cooldown_s <= 0.0 and entity.health.hp < max_regen) {
                entity.health.hp = @min(entity.health.hp + regen_speed * delta_s, max_regen);
            }
            entity.health.regen_cooldown_s = @max(entity.health.regen_cooldown_s - delta_s, 0.0);

            // Update invulnerability
            entity.health.invulnerable_s = @max(entity.health.invulnerable_s - delta_s, 0.0);
        }
    }

    // Update ships
    {
        var it = entities.iterator(.{
            .ship = .{},
            .rb = .{ .mutable = true },
            .transform = .{ .mutable = true },
            .player_index = .{},
            .animation_player = .{ .optional = true, .mutable = true },
        });
        while (it.next()) |entity| {
            const input_state = &game.input_state[entity.player_index.*];
            if (entity.ship.omnithrusters) {
                entity.rb.vel.add(.{
                    .x = input_state.getAxis(.thrust_x) * entity.ship.thrust * delta_s,
                    .y = input_state.getAxis(.thrust_y) * entity.ship.thrust * delta_s,
                });
            } else {
                // convert to 1.0 or 0.0
                entity.transform.angle = @mod(
                    entity.transform.angle + input_state.getAxis(.turn) * entity.ship.turn_speed * delta_s,
                    2 * math.pi,
                );

                const thrust_input: f32 = @floatFromInt(@intFromBool(input_state.isAction(.thrust_forward, .positive, .active)));
                const thrust = V.unit(entity.transform.angle);
                entity.rb.vel.add(thrust.scaled(thrust_input * entity.ship.thrust * delta_s));
            }
        }
    }

    // Update animate on input
    {
        var it = entities.iterator(.{
            .player_index = .{},
            .animate_on_input = .{},
            .animation_player = .{ .mutable = true },
        });
        while (it.next()) |entity| {
            const input_state = &game.input_state[entity.player_index.*];
            if (input_state.isAction(entity.animate_on_input.action, entity.animate_on_input.direction, .activated)) {
                entity.animation_player.* = .{
                    .id = entity.animate_on_input.activated,
                };
            } else if (input_state.isAction(entity.animate_on_input.action, entity.animate_on_input.direction, .deactivated)) {
                entity.animation_player.* = .{
                    .id = entity.animate_on_input.deactivated,
                };
            }
        }
    }

    // TODO: break out cooldown logic or no?
    // Update grapple guns
    {
        var it = entities.iterator(.{
            .grapple_gun = .{ .mutable = true },
            .player_index = .{},
            .rb = .{},
            .transform = .{},
        });
        while (it.next()) |entity| {
            var gg = entity.grapple_gun;
            var rb = entity.rb;
            gg.cooldown_s -= delta_s;
            const input_state = &game.input_state[entity.player_index.*];
            if (input_state.isAction(.fire, .positive, .activated) and gg.cooldown_s <= 0) {
                gg.cooldown_s = gg.max_cooldown_s;

                // TODO: increase cooldown_s?
                if (gg.live) |live| {
                    for (live.joints) |piece| {
                        command_buffer.appendRemove(piece);
                    }
                    for (live.springs) |piece| {
                        command_buffer.appendRemove(piece);
                    }
                    command_buffer.appendRemove(live.hook);
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
                    var dir = V.unit(entity.transform.angle + gg.angle);
                    var vel = rb.vel;
                    const segment_len = 50.0;
                    var pos = entity.transform.pos.plus(dir.scaled(segment_len));
                    for (0..gg.live.?.joints.len) |i| {
                        gg.live.?.joints[i] = entities.create(.{
                            .transform = .{
                                .pos = pos,
                            },
                            .rb = .{
                                .vel = vel,
                                .radius = 2,
                                .density = 0.001,
                            },
                            // TODO: ...
                            // .sprite_renderer = .@"img/bullet/small.png",
                        });
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
                    gg.live.?.hook = entities.create(.{
                        .transform = .{
                            .pos = pos,
                            .angle = 0,
                        },
                        .rb = .{
                            .vel = vel,
                            .rotation_vel = 0,
                            .radius = 2,
                            .density = 0.001,
                        },
                        .collider = .{
                            .collision_damping = 0,
                            .layer = .hook,
                        },
                        .hook = hook,
                        // TODO: ...
                        // .sprite_renderer = .@"img/bullet/small.png",
                    });
                    for (0..(gg.live.?.springs.len)) |i| {
                        gg.live.?.springs[i] = entities.create(.{
                            .spring = .{
                                .start = if (i == 0)
                                    it.handle()
                                else
                                    gg.live.?.joints[i - 1],
                                .end = if (i < gg.live.?.joints.len)
                                    gg.live.?.joints[i]
                                else
                                    gg.live.?.hook,
                                .k = hook.k,
                                .length = segment_len,
                                .damping = hook.damping,
                            },
                        });
                    }
                }
            }
        }
    }

    // Update animations
    {
        var it = entities.iterator(.{ .animation_player = .{} });
        while (it.next()) |entity| {
            if (entity.animation_player.destroys_entity and entity.animation_player.id == null) {
                command_buffer.appendRemove(it.handle());
            }
        }
    }

    // Update lifetimes
    {
        var it = entities.iterator(.{ .lifetime = .{ .mutable = true } });
        while (it.next()) |entity| {
            entity.lifetime.seconds -= delta_s;
            if (entity.lifetime.seconds <= 0) {
                command_buffer.appendRemove(it.handle());
            }
        }
    }

    // Update cached world positions and angles
    {
        var it = entities.iterator(.{ .transform = .{ .mutable = true } });
        while (it.next()) |entity| {
            entity.transform.pos_world_cached = V.zero;
            entity.transform.angle_world_cached = 0;

            var parent_it = parenting.iterator(entities, it.handle());
            while (parent_it.next()) |current| {
                if (entities.getComponent(current, .transform)) |transform| {
                    entity.transform.pos_world_cached.add(transform.pos);
                    entity.transform.angle_world_cached += transform.angle;
                } else break;
            }
        }
    }

    // Update turrets
    {
        var it = entities.iterator(.{
            .turret = .{ .mutable = true },
            .player_index = .{},
            .rb = .{},
            .transform = .{},
        });
        while (it.next()) |entity| {
            var angle = entity.transform.angle_world_cached;
            var vel = V.unit(angle).scaled(entity.turret.projectile_speed).plus(entity.rb.vel);
            var sprite: SpriteId = .@"img/bullet/small.png";
            if (entity.turret.aim_opposite_movement) {
                angle = entity.rb.vel.angle() + std.math.pi;
                vel = V.zero;
                sprite = .@"img/bullet/shiny.png";
            }
            const fire_pos = entity.transform.pos_world_cached.plus(V.unit(angle + entity.turret.angle).scaled(entity.turret.radius + entity.turret.projectile_radius));
            const ready = switch (entity.turret.cooldown) {
                .time => |*time| r: {
                    time.current_s -= delta_s;
                    break :r time.current_s <= 0;
                },
                .distance => |dist| if (dist.last_pos) |last_pos|
                    fire_pos.distanceSqrd(last_pos) >= dist.min_sq
                else
                    true,
            };
            const input_state = &game.input_state[entity.player_index.*];
            if (input_state.isAction(.fire, .positive, .active) and ready) {
                switch (entity.turret.cooldown) {
                    .time => |*time| time.current_s = time.max_s,
                    .distance => |*dist| dist.last_pos = fire_pos,
                }
                // TODO(mason): just make separate component for wall
                _ = command_buffer.appendInstantiate(true, &.{
                    .{
                        .damage = .{
                            .hp = entity.turret.projectile_damage,
                        },
                        .transform = .{
                            .pos = fire_pos,
                            .angle = vel.angle() + math.pi / 2.0,
                        },
                        .rb = .{
                            .vel = vel,
                            .rotation_vel = 0,
                            .radius = entity.turret.projectile_radius,
                            // TODO(mason): modify math to accept 0 and inf mass
                            .density = entity.turret.projectile_density,
                        },
                        .sprite_renderer = sprite,
                        .collider = .{
                            // Lasers gain energy when bouncing off of rocks
                            .collision_damping = 1,
                            .layer = .projectile,
                        },
                        .lifetime = .{
                            .seconds = entity.turret.projectile_lifetime,
                        },
                    },
                });
            }
        }
    }

    // Apply queued deletions
    command_buffer.execute();
    command_buffer.clearRetainingCapacity();
}

// TODO(mason): allow passing in const for rendering to make sure no modifications
fn render(renderer: *Renderer, entities: *Entities, game: Game, delta_s: f32, fx_loop_s: f32) void {
    // This was added for the flash effect and then not used since it already requires a timer
    // state. We'll be wanting it later and I don't feel like deleting and retyping the explanation
    // for it.
    _ = fx_loop_s;

    // Clear screen
    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer.sdl, 0x00, 0x00, 0x00, 0xff));
    sdlAssertZero(c.SDL_RenderClear(renderer.sdl));

    // Draw stars
    for (game.stars) |star| {
        const sprite = renderer.sprites.get(switch (star.kind) {
            .small => .@"img/star/small.png",
            .large => .@"img/star/large.png",
            .planet_red => .@"img/planet-red.png",
        });
        const dst_rect: c.SDL_Rect = .{
            .x = star.x,
            .y = star.y,
            .w = sprite.rect.w,
            .h = sprite.rect.h,
        };
        sdlAssertZero(c.SDL_RenderCopy(
            renderer.sdl,
            sprite.tints[0],
            null,
            &dst_rect,
        ));
    }

    // Draw ring
    {
        const sprite = renderer.sprites.get(.@"img/ring.png");
        sdlAssertZero(c.SDL_RenderCopy(
            renderer.sdl,
            sprite.tints[0],
            null,
            &sprite.toSdlRect(display_center),
        ));
    }

    // Draw animations
    {
        var it = entities.iterator(.{
            .rb = .{},
            .transform = .{},
            .animation_player = .{ .mutable = true },
            .health = .{ .optional = true },
            .team_index = .{ .optional = true },
            .parent = .{ .optional = true },
        });
        draw: while (it.next()) |entity| {
            // Skip if we're flashing
            if (flash_off(entities, it.handle())) {
                continue :draw;
            }

            // Skip if we have no current animation
            if (entity.animation_player.id == null) {
                continue :draw;
            }

            // Get the current frame
            const animation = asset_index.animations.get(entity.animation_player.id.?);
            var frame_index: u32 = @intFromFloat(entity.animation_player.time_passed * animation.fps);

            // Apply looping
            if (frame_index >= animation.frames.len) {
                if (animation.loop_start) |loop_start| {
                    frame_index = loop_start;
                    entity.animation_player.time_passed -= @as(f32, @floatFromInt(animation.frames.len - loop_start)) / animation.fps;
                } else {
                    entity.animation_player.id = null;
                    continue :draw;
                }
            }

            // Update the timer
            entity.animation_player.time_passed += delta_s;

            // Draw the current frame
            const sprite = renderer.sprites.get(animation.frames[frame_index]);
            const unscaled_sprite_size = sprite.size();
            const sprite_radius = (unscaled_sprite_size.x + unscaled_sprite_size.y) / 4.0;
            const size_coefficient = entity.rb.radius / sprite_radius;
            const sprite_size = unscaled_sprite_size.scaled(size_coefficient);
            var dest_rect = sdlRect(entity.transform.pos_world_cached.minus(sprite_size.scaled(0.5)), sprite_size);

            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer.sdl,
                sprite.getTint(if (entity.team_index) |i| i.* else null),
                null, // source rectangle
                &dest_rect,
                toDegrees(entity.transform.angle_world_cached + animation.angle + sprite.angle),
                null, // center of angle
                c.SDL_FLIP_NONE,
            ));
        }
    }

    // Draw health bars
    {
        var it = entities.iterator(.{ .health = .{}, .rb = .{}, .transform = .{} });
        while (it.next()) |entity| {
            if (entity.health.hp < entity.health.max_hp) {
                const health_bar_size: V = .{ .x = 32, .y = 4 };
                var start = entity.transform.pos.minus(health_bar_size.scaled(0.5)).floored();
                start.y -= entity.rb.radius + health_bar_size.y;
                sdlAssertZero(c.SDL_SetRenderDrawColor(renderer.sdl, 0xff, 0xff, 0xff, 0xff));
                sdlAssertZero(c.SDL_RenderFillRect(renderer.sdl, &sdlRect(
                    start.minus(.{ .x = 1, .y = 1 }),
                    health_bar_size.plus(.{ .x = 2, .y = 2 }),
                )));
                const hp_percent = entity.health.hp / entity.health.max_hp;
                if (hp_percent >= entity.health.regen_ratio) {
                    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer.sdl, 0x00, 0x94, 0x13, 0xff));
                } else if (entity.health.regen_cooldown_s > 0.0) {
                    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer.sdl, 0xe2, 0x00, 0x03, 0xff));
                } else {
                    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer.sdl, 0xff, 0x7d, 0x03, 0xff));
                }
                sdlAssertZero(c.SDL_RenderFillRect(renderer.sdl, &sdlRect(
                    start,
                    .{ .x = health_bar_size.x * hp_percent, .y = health_bar_size.y },
                )));
            }
        }
    }

    // Draw sprites
    // TODO(mason): sort draw calls somehow (can the sdl renderer do depth buffers?)
    {
        var it = entities.iterator(.{
            .sprite_renderer = .{},
            .rb = .{},
            .transform = .{},
            .team_index = .{ .optional = true },
        });
        draw: while (it.next()) |entity| {
            if (flash_off(entities, it.handle())) {
                continue :draw;
            }
            const sprite = renderer.sprites.get(entity.sprite_renderer.*);
            const unscaled_sprite_size = sprite.size();
            const sprite_radius = (unscaled_sprite_size.x + unscaled_sprite_size.y) / 4.0;
            const size_coefficient = entity.rb.radius / sprite_radius;
            const sprite_size = unscaled_sprite_size.scaled(size_coefficient);
            const dest_rect = sdlRect(entity.transform.pos.minus(sprite_size.scaled(0.5)), sprite_size);
            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer.sdl,
                sprite.getTint(if (entity.team_index) |i| i.* else null),
                null, // source rectangle
                &dest_rect,
                toDegrees(entity.transform.angle + sprite.angle),
                null, // center of rotation
                c.SDL_FLIP_NONE,
            ));
        }
    }

    // TODO(mason): don't draw springs, have a themed grapple effect that is its own components and
    // gets drawn from spring start to end. we may have other uses for springs that may not look the
    // same!
    // Draw springs
    {
        var it = entities.iterator(.{ .spring = .{} });
        while (it.next()) |entity| {
            var start = (entities.getComponent(entity.spring.start, .transform) orelse continue).pos;
            var end = (entities.getComponent(entity.spring.end, .transform) orelse continue).pos;
            sdlAssertZero(c.SDL_SetRenderDrawColor(renderer.sdl, 0xff, 0xff, 0xff, 0xff));
            sdlAssertZero(c.SDL_RenderDrawLine(
                renderer.sdl,
                @intFromFloat(@floor(start.x)),
                @intFromFloat(@floor(start.y)),
                @intFromFloat(@floor(end.x)),
                @intFromFloat(@floor(end.y)),
            ));
        }
    }

    // Draw the ships in the bank.
    {
        const row_height = 64;
        const col_width = 64;
        const top_left: V = .{ .x = 20, .y = 20 };

        for (game.teams, 0..) |team, team_index| {
            {
                const sprite = renderer.sprites.get(.@"img/particle.png");
                const pos = top_left.plus(.{
                    .x = col_width * @as(f32, @floatFromInt(team_index)),
                    .y = 0,
                });
                sdlAssertZero(c.SDL_RenderCopy(
                    renderer.sdl,
                    sprite.getTint(team_index),
                    null,
                    &sprite.toSdlRect(pos),
                ));
            }
            for (team.ship_progression, 0..) |class, display_prog_index| {
                const dead = team.ship_progression_index > display_prog_index;
                if (dead) continue;

                const sprite = renderer.sprites.get(Game.shipLifeSprite(class));
                const pos = top_left.plus(.{
                    .x = col_width * @as(f32, @floatFromInt(team_index)),
                    .y = row_height * @as(f32, @floatFromInt(display_prog_index)),
                });
                const sprite_size = sprite.size().scaled(0.5);
                const dest_rect = sdlRect(pos.minus(sprite_size.scaled(0.5)), sprite_size);
                sdlAssertZero(c.SDL_RenderCopy(
                    renderer.sdl,
                    sprite.getTint(team_index),
                    null,
                    &dest_rect,
                ));
            }
        }
    }

    c.SDL_RenderPresent(renderer.sdl);
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

const User = union(enum) {
    player_index: usize,
    npc: EntityHandle,
};

const Damage = struct {
    hp: f32,
};

/// A spring connecting to entities.
///
/// You can simulate a rod by choosing a high spring constant and setting the damping factor to 1.0.
const Spring = struct {
    start: EntityHandle,
    end: EntityHandle,

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

const Lifetime = struct {
    seconds: f32,
};

const Animation = struct {
    id: ?AnimationId,
    /// number of seconds passed since Animation start.
    time_passed: f32 = 0,
    destroys_entity: bool = false,
};

const Cooldown = union(enum) {
    time: struct {
        max_s: f32,
        current_s: f32 = 0.0,
    },
    distance: struct {
        min_sq: f32,
        last_pos: ?V = null,
    },
};

const Turret = struct {
    /// Together with angle, this is the location of the turret from the center
    /// of the containing object. Pixels.
    radius: f32,
    /// Together with radius, this is the location of the turret from the
    /// center of the containing object. Radians.
    angle: f32,
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
        springs: [segments]EntityHandle,
        joints: [segments - 1]EntityHandle,
        hook: EntityHandle,
    } = null,
};

const Transform = struct {
    // parent: ?EntityHandle = null,
    /// pixels, relative to parent
    pos: V = V.zero,
    /// radians
    angle: f32 = 0.0,
    pos_world_cached: V = undefined,
    angle_world_cached: f32 = undefined,
};

const AnimateOnInput = struct {
    action: input_system.Action,
    direction: input_system.Direction,
    activated: ?AnimationId,
    deactivated: ?AnimationId,
};

const RigidBody = struct {
    fn mass(self: RigidBody) f32 {
        return self.density * math.pi * self.radius * self.radius;
    }

    /// pixels per second
    vel: V = .{ .x = 0, .y = 0 },
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
    const Self = @This();

    tints: []*c.SDL_Texture,
    rect: c.SDL_Rect,
    angle: f32,

    // If this sprite supports tinting, returns the tint. Otherwise returns the default tint.
    fn getTint(self: *const @This(), index: ?usize) *c.SDL_Texture {
        if (index != null and self.tints.len > 1) {
            return self.tints[index.?];
        }
        return self.tints[0];
    }

    fn deinit(self: *@This(), allocator: Allocator) void {
        allocator.free(self.tints);
        self.* = undefined;
    }

    /// Assumes the pos points to the center of the sprite.
    fn toSdlRect(self: Self, pos: V) c.SDL_Rect {
        const sprite_size = self.size();
        return sdlRect(pos.minus(sprite_size.scaled(0.5)), sprite_size);
    }

    fn size(self: Self) V {
        return .{
            .x = @floatFromInt(self.rect.w),
            .y = @floatFromInt(self.rect.h),
        };
    }

    fn radius(self: Self) f32 {
        const s = self.size();
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
    controllers: [4]?*c.SDL_GameController = .{ null, null, null, null },
    control_schemes: [4]input_system.ControlScheme,
    input_state: [4]input_system.InputState,
    teams_buffer: [4]Team,
    teams: []Team,

    stars: [150]Star,

    const ShipAnimations = struct {
        thrusters_forward: ?Animation.Index = null,
        thrusters_left: ?Animation.Index = null,
        thrusters_right: ?Animation.Index = null,
        thrusters_top: ?Animation.Index = null,
        thrusters_bottom: ?Animation.Index = null,
    };

    const shrapnel_sprites = [_]SpriteId{
        .@"img/shrapnel/01.png",
        .@"img/shrapnel/02.png",
        .@"img/shrapnel/03.png",
    };

    const rock_sprites = [_]SpriteId{
        .@"img/rock-a.png",
        .@"img/rock-b.png",
        .@"img/rock-c.png",
    };

    fn createRanger(
        command_buffer: *CommandBuffer,
        player_index: u2,
        team_index: u2,
        pos: V,
        angle: f32,
    ) PrefabHandle {
        const radius = 16;
        const ship_handle = PrefabHandle.init(0);
        return command_buffer.appendInstantiate(true, &.{
            .{
                .ship = .{
                    .class = .ranger,
                    .turn_speed = math.pi * 1.0,
                    .thrust = 160,
                },
                .health = .{
                    .hp = 80,
                    .max_hp = 80,
                },
                .transform = .{
                    .pos = pos,
                    .angle = angle,
                },
                .rb = .{
                    .vel = .{ .x = 0, .y = 0 },
                    .radius = radius,
                    .rotation_vel = 0.0,
                    .density = 0.02,
                },
                .collider = .{
                    .collision_damping = 0.4,
                    .layer = .vehicle,
                },
                .sprite_renderer = .@"img/ship/ranger/diffuse.png",
                .turret = .{
                    .angle = 0,
                    .radius = radius,
                    .cooldown = .{ .time = .{ .max_s = 0.1 } },
                    .projectile_speed = 550,
                    .projectile_lifetime = 1.0,
                    .projectile_damage = 6,
                    .projectile_radius = 8,
                },
                .player_index = player_index,
                .team_index = team_index,
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = AnimateOnInput{
                    .action = .thrust_forward,
                    .direction = .positive,
                    .activated = .@"ship/ranger/thrusters",
                    .deactivated = null,
                },
                .animation_player = .{
                    .id = null,
                },
                .player_index = player_index,
                .team_index = team_index,
            },
        }).?;
    }

    fn createTriangle(
        command_buffer: *CommandBuffer,
        player_index: u2,
        team_index: u2,
        pos: V,
        angle: f32,
    ) PrefabHandle {
        const radius = 24;
        const ship_handle = PrefabHandle.init(0);
        return command_buffer.appendInstantiate(true, &.{
            .{
                .ship = .{
                    .class = .triangle,
                    .turn_speed = math.pi * 0.9,
                    .thrust = 250,
                },
                .health = .{
                    .hp = 100,
                    .max_hp = 100,
                    .regen_ratio = 0.5,
                },
                .transform = .{
                    .pos = pos,
                    .angle = angle,
                },
                .rb = .{
                    .vel = .{ .x = 0, .y = 0 },
                    .radius = 26,
                    .rotation_vel = 0.0,
                    .density = 0.02,
                },
                .collider = .{
                    .collision_damping = 0.4,
                    .layer = .vehicle,
                },
                .sprite_renderer = .@"img/ship/triangle/diffuse.png",
                .turret = .{
                    .angle = 0,
                    .radius = radius,
                    .cooldown = .{ .time = .{ .max_s = 0.2 } },
                    .projectile_speed = 700,
                    .projectile_lifetime = 1.0,
                    .projectile_damage = 12,
                    .projectile_radius = 12,
                },
                .player_index = player_index,
                .team_index = team_index,
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_forward,
                    .direction = .positive,
                    .activated = .@"ship/triangle/thrusters",
                    .deactivated = null,
                },
                .animation_player = .{ .id = null },
                .player_index = player_index,
                .team_index = team_index,
            },
        }).?;
    }

    fn createMilitia(
        command_buffer: *CommandBuffer,
        player_index: u2,
        team_index: u2,
        pos: V,
        angle: f32,
    ) PrefabHandle {
        const radius = 24;
        const ship_handle = PrefabHandle.init(0);
        return command_buffer.appendInstantiate(true, &.{
            .{
                .ship = .{
                    .class = .militia,
                    .turn_speed = math.pi * 1.4,
                    .thrust = 400,
                },
                .health = .{
                    .hp = 80,
                    .max_hp = 80,
                },
                .transform = .{
                    .pos = pos,
                    .angle = angle,
                },
                .rb = .{
                    .vel = .{ .x = 0, .y = 0 },
                    .rotation_vel = 0.0,
                    .radius = radius,
                    .density = 0.06,
                },
                .collider = .{
                    .collision_damping = 0.4,
                    .layer = .vehicle,
                },
                .sprite_renderer = .@"img/ship/militia/diffuse.png",
                // .grapple_gun = .{
                //     .radius = radius * 10.0,
                //     .angle = 0,
                //     .cooldown_s = 0,
                //     .max_cooldown_s = 0.2,
                //     // TODO: when nonzero, causes the ship to move. wouldn't happen if there was equal
                //     // kickback!
                //     .projectile_speed = 0,
                // },
                .player_index = player_index,
                .team_index = team_index,
                .front_shield = .{},
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_forward,
                    .direction = .positive,
                    .activated = .@"ship/militia/thrusters",
                    .deactivated = null,
                },
                .animation_player = .{
                    .id = null,
                },
                .player_index = player_index,
                .team_index = team_index,
            },
        }).?;
    }

    fn createKevin(
        command_buffer: *CommandBuffer,
        player_index: u2,
        team_index: u2,
        pos: V,
        angle: f32,
    ) PrefabHandle {
        const ship_handle = PrefabHandle.init(0);

        const radius = 32;
        return command_buffer.appendInstantiate(true, &.{
            .{
                .ship = .{
                    .class = .kevin,
                    .turn_speed = math.pi * 1.1,
                    .thrust = 300,
                },
                .health = .{
                    .hp = 300,
                    .max_hp = 300,
                },
                .transform = .{
                    .pos = pos,
                    .angle = angle,
                },
                .rb = .{
                    .vel = .{ .x = 0, .y = 0 },
                    .radius = radius,
                    .rotation_vel = 0.0,
                    .density = 0.02,
                },
                .collider = .{
                    .collision_damping = 0.4,
                    .layer = .vehicle,
                },
                .sprite_renderer = .@"img/ship/kevin/diffuse.png",
                .player_index = player_index,
                .team_index = team_index,
            },
            .{
                .parent = ship_handle.relative,
                .turret = .{
                    .radius = 32,
                    .angle = math.pi * 0.1,
                    .cooldown = .{ .time = .{ .max_s = 0.2 } },
                    .projectile_speed = 500,
                    .projectile_lifetime = 1.0,
                    .projectile_damage = 18,
                    .projectile_radius = 18,
                },
                .player_index = player_index,
                .team_index = team_index,
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .transform = .{},
            },
            .{
                .parent = ship_handle.relative,
                .turret = .{
                    .radius = radius,
                    .angle = math.pi * -0.1,
                    .cooldown = .{ .time = .{ .max_s = 0.2 } },
                    .projectile_speed = 500,
                    .projectile_lifetime = 1.0,
                    .projectile_damage = 18,
                    .projectile_radius = 18,
                },
                .player_index = player_index,
                .team_index = team_index,
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .transform = .{},
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_forward,
                    .direction = .positive,
                    .activated = .@"ship/kevin/thrusters",
                    .deactivated = null,
                },
                .animation_player = .{
                    .id = null,
                },
                .player_index = player_index,
                .team_index = team_index,
            },
        }).?;
    }

    fn createWendy(
        command_buffer: *CommandBuffer,
        player_index: u2,
        team_index: u2,
        pos: V,
        _: f32,
    ) PrefabHandle {
        const radius = 32;
        const ship_handle = PrefabHandle.init(0);
        return command_buffer.appendInstantiate(true, &.{
            .{
                .ship = .{
                    .class = .wendy,
                    .turn_speed = math.pi * 1.0,
                    .thrust = 200,
                    .omnithrusters = true,
                },
                .health = .{
                    .hp = 400,
                    .max_hp = 400,
                },
                .transform = .{
                    .pos = pos,
                },
                .rb = .{
                    .vel = .{ .x = 0, .y = 0 },
                    .radius = radius,
                    .rotation_vel = 0.0,
                    .density = 0.02,
                },
                .collider = .{
                    .collision_damping = 0.4,
                    .layer = .vehicle,
                },
                .sprite_renderer = .@"img/ship/wendy/diffuse.png",
                .turret = .{
                    .radius = radius,
                    .angle = 0,
                    .cooldown = .{ .distance = .{ .min_sq = std.math.pow(f32, 10.0, 2.0) } },
                    .projectile_speed = 0,
                    .projectile_lifetime = 5.0,
                    .projectile_damage = 50,
                    .projectile_radius = 8,
                    .projectile_density = std.math.inf(f32),
                    .aim_opposite_movement = true,
                },
                .player_index = player_index,
                .team_index = team_index,
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_y,
                    .direction = .positive,
                    .activated = .@"ship/wendy/thrusters/left",
                    .deactivated = null,
                },
                .animation_player = .{
                    .id = null,
                },
                .player_index = player_index,
                .team_index = team_index,
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_y,
                    .direction = .negative,
                    .activated = .@"ship/wendy/thrusters/right",
                    .deactivated = null,
                },
                .animation_player = .{
                    .id = null,
                },
                .player_index = player_index,
                .team_index = team_index,
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_x,
                    .direction = .negative,
                    .activated = .@"ship/wendy/thrusters/top",
                    .deactivated = null,
                },
                .animation_player = .{
                    .id = null,
                },
                .player_index = player_index,
                .team_index = team_index,
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_x,
                    .direction = .positive,
                    .activated = .@"ship/wendy/thrusters/bottom",
                    .deactivated = null,
                },
                .animation_player = .{
                    .id = null,
                },
                .player_index = player_index,
                .team_index = team_index,
            },
        }).?;
    }

    fn createShrapnel(command_buffer: *CommandBuffer, pos: V, vel: V) PrefabHandle {
        const shrapnel_sprite = Game.shrapnel_sprites[
            std.crypto.random.uintLessThanBiased(usize, Game.shrapnel_sprites.len)
        ];
        return command_buffer.appendInstantiate(true, &.{
            .{
                .lifetime = .{
                    .seconds = 1.5 + std.crypto.random.float(f32) * 1.0,
                },
                .transform = .{
                    .pos = pos,
                    .angle = 2 * math.pi * std.crypto.random.float(f32),
                },
                .rb = .{
                    .vel = vel,
                    .rotation_vel = 2 * math.pi * std.crypto.random.float(f32),
                    .radius = lerp(1.75, 3.5, std.crypto.random.float(f32)),
                    .density = 0.001,
                },
                .sprite_renderer = shrapnel_sprite,
            },
        }).?;
    }

    fn init() !Game {
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
                .positive = c.SDL_SCANCODE_S,
                .negative = c.SDL_SCANCODE_W,
            },
            .fire = .{
                .positive = c.SDL_SCANCODE_LSHIFT,
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
                .positive = c.SDL_SCANCODE_DOWN,
                .negative = c.SDL_SCANCODE_UP,
            },
            .fire = .{
                .positive = c.SDL_SCANCODE_RSHIFT,
            },
        };
        const keyboard_none: input_system.ControlScheme.Keyboard = .{
            .turn = .{},
            .thrust_forward = .{},
            .thrust_x = .{},
            .thrust_y = .{},
            .fire = .{},
        };

        return .{
            .teams = undefined,
            .teams_buffer = undefined,
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

            .stars = undefined,
        };
    }

    fn createShip(
        game: *Game,
        command_buffer: *CommandBuffer,
        player_index: u2,
        team_index: u2,
        pos: V,
        angle: f32,
    ) PrefabHandle {
        const team = &game.teams[team_index];
        const progression_index = team.ship_progression_index;
        team.ship_progression_index += 1;
        return switch (team.ship_progression[progression_index]) {
            .ranger => Game.createRanger(command_buffer, player_index, team_index, pos, angle),
            .militia => Game.createMilitia(command_buffer, player_index, team_index, pos, angle),
            .triangle => Game.createTriangle(command_buffer, player_index, team_index, pos, angle),
            .kevin => Game.createKevin(command_buffer, player_index, team_index, pos, angle),
            .wendy => Game.createWendy(command_buffer, player_index, team_index, pos, angle),
        };
    }

    fn shipLifeSprite(class: Ship.Class) SpriteId {
        return switch (class) {
            .ranger => .@"img/ship/ranger/diffuse.png",
            .militia => .@"img/ship/militia/diffuse.png",
            .triangle => .@"img/ship/triangle/diffuse.png",
            .kevin => .@"img/ship/kevin/diffuse.png",
            .wendy => .@"img/ship/wendy/diffuse.png",
        };
    }

    const Scenario = enum {
        deathmatch_2v2,
        deathmatch_2v2_no_rocks,
        deathmatch_2v2_one_rock,
        deathmatch_1v1,
        deathmatch_1v1_one_rock,
        royale_4p,
    };

    fn setupScenario(game: *Game, command_buffer: *CommandBuffer, scenario: Scenario) void {
        command_buffer.entities.clearRetainingCapacity();

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
                const pos = display_center.plus(V.unit(angle).scaled(50));
                const player_index: u2 = @intCast(i);
                _ = game.createShip(command_buffer, player_index, team_index, pos, angle);
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
        for (0..rock_amt) |_| {
            const speed = 20 + std.crypto.random.float(f32) * 300;
            const radius = 25 + std.crypto.random.float(f32) * 110;
            const sprite = Game.rock_sprites[std.crypto.random.uintLessThanBiased(usize, Game.rock_sprites.len)];
            const pos = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                .scaled(lerp(display_radius, display_radius * 1.1, std.crypto.random.float(f32)))
                .plus(display_center);

            _ = command_buffer.appendInstantiate(true, &.{
                .{
                    .sprite_renderer = sprite,
                    .transform = .{
                        .pos = pos,
                    },
                    .rb = .{
                        .vel = V.unit(std.crypto.random.float(f32) * math.pi * 2).scaled(speed),
                        .rotation_vel = lerp(-1.0, 1.0, std.crypto.random.float(f32)),
                        .radius = radius,
                        .density = 0.10,
                    },
                    .collider = .{
                        .collision_damping = 1,
                        .layer = .hazard,
                    },
                },
            });
        }

        // Create stars
        generateStars(&game.stars);
    }

    fn spawnTeamVictory(entities: *Entities, pos: V, team_index: u2) void {
        for (0..500) |_| {
            const random_vel = V.unit(std.crypto.random.float(f32) * math.pi * 2).scaled(300);
            _ = entities.create(.{
                .lifetime = .{
                    .seconds = 1000,
                },
                .transform = .{
                    .pos = pos,
                    .angle = 2 * math.pi * std.crypto.random.float(f32),
                },
                .rb = .{
                    .vel = random_vel,
                    .rotation_vel = 2 * math.pi * std.crypto.random.float(f32),
                    .radius = 16,
                    .density = 0.001,
                },
                .sprite_renderer = .@"img/particle.png",
                .team_index = team_index,
            });
        }
    }

    fn aliveTeam(game: Game) u2 {
        for (game.teams, 0..) |team, i| {
            if (team.players_alive > 0) return @intCast(i);
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

const Renderer = struct {
    gpa: Allocator,
    sdl: *c.SDL_Renderer,
    dir: std.fs.Dir,
    sprites: std.EnumArray(SpriteId, Sprite),

    fn init(gpa: Allocator, sdl: *c.SDL_Renderer) !Renderer {
        const self_exe_dir_path = try std.fs.selfExeDirPathAlloc(gpa);
        defer gpa.free(self_exe_dir_path);
        const assets_dir_path = try std.fs.path.join(gpa, &.{ self_exe_dir_path, "data" });
        defer gpa.free(assets_dir_path);
        var dir = std.fs.openDirAbsolute(assets_dir_path, .{}) catch |err| {
            panic("unable to open assets directory '{s}': {s}", .{
                assets_dir_path, @errorName(err),
            });
        };

        var sprites = std.EnumArray(SpriteId, Sprite).initUndefined();
        inline for (@typeInfo(SpriteId).Enum.fields) |field| {
            const id: SpriteId = @enumFromInt(field.value);
            const sprite = try loadSprite(gpa, dir, sdl, id);
            sprites.set(id, sprite);
        }

        return .{
            .gpa = gpa,
            .sdl = sdl,
            .dir = dir,
            .sprites = sprites,
        };
    }

    fn deinit(a: *Renderer) void {
        a.dir.close();
        a.* = undefined;
    }

    fn loadSprite(allocator: Allocator, dir: std.fs.Dir, sdl: *c.SDL_Renderer, sprite_id: SpriteId) !Sprite {
        const config = asset_index.sprites.get(sprite_id);
        var tint_mask_path: ?[]const u8 = null;
        var tints: []const [3]u8 = &.{};
        if (config.tint) |tint| {
            tints = &.{
                .{ 16, 124, 196 },
                .{ 237, 210, 64 },
                .{ 224, 64, 237 },
                .{ 83, 237, 64 },
            };
            tint_mask_path = tint.mask_path;
        }
        const diffuse_png = try dir.readFileAlloc(allocator, asset_index.sprites.get(sprite_id).path, 50 * 1024 * 1024);
        defer allocator.free(diffuse_png);
        const tint_mask_png = if (tint_mask_path) |m|
            try dir.readFileAlloc(allocator, m, 50 * 1024 * 1024)
        else
            null;
        defer if (tint_mask_png) |m| allocator.free(m);
        return try spriteFromBytes(allocator, diffuse_png, tint_mask_png, sdl, tints, config.angle);
    }

    fn spriteFromBytes(allocator: Allocator, png_diffuse: []const u8, png_recolor: ?[]const u8, sdl: *c.SDL_Renderer, tints: []const [3]u8, angle: f32) !Sprite {
        var width: c_int = undefined;
        var height: c_int = undefined;
        const channel_count = 4;
        const bits_per_channel = 8;
        const diffuse_buffer = c.stbi_load_from_memory(
            png_diffuse.ptr,
            @intCast(png_diffuse.len),
            &width,
            &height,
            null,
            channel_count,
        );
        defer c.stbi_image_free(diffuse_buffer);
        const diffuse_data = diffuse_buffer[0 .. @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * channel_count];
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
        errdefer textures.deinit(allocator);
        for (tints) |tint| {
            const diffuse_copy = try allocator.dupe(u8, diffuse_data);
            defer allocator.free(diffuse_copy);

            for (0..diffuse_copy.len / channel_count) |pixel| {
                var r = &diffuse_copy[pixel * channel_count];
                var g = &diffuse_copy[pixel * channel_count + 1];
                var b = &diffuse_copy[pixel * channel_count + 2];

                var color: [3]f32 = .{
                    @as(f32, @floatFromInt(r.*)) / 255.0,
                    @as(f32, @floatFromInt(g.*)) / 255.0,
                    @as(f32, @floatFromInt(b.*)) / 255.0,
                };

                // Change gama
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
                    var recolored = math.pow(f32, @as(f32, @floatFromInt(tint_channel)) / 255.0, 1.0 / gamma);
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
            textures.appendAssumeCapacity(c.SDL_CreateTextureFromSurface(sdl, surface) orelse
                panic("unable to convert surface to texture", .{}));
        } else {
            const pitch = width * channel_count;
            const surface = c.SDL_CreateRGBSurfaceFrom(
                diffuse_data.ptr,
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
            try textures.append(allocator, c.SDL_CreateTextureFromSurface(sdl, surface) orelse
                panic("unable to convert surface to texture", .{}));
        }
        return .{
            .angle = angle,
            .tints = textures.items,
            .rect = .{ .x = 0, .y = 0, .w = width, .h = height },
        };
    }
};

const Star = struct {
    x: i32,
    y: i32,
    kind: Kind,

    const Kind = enum { large, small, planet_red };
};

fn generateStars(stars: []Star) void {
    for (stars) |*star| {
        star.* = .{
            .x = std.crypto.random.uintLessThanBiased(u31, display_width),
            .y = std.crypto.random.uintLessThanBiased(u31, display_height),
            .kind = @enumFromInt(std.crypto.random.uintLessThanBiased(u8, 2)),
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
    return 360.0 * (radians / (2 * math.pi));
}

fn sdlRect(top_left_pos: V, size: V) c.SDL_Rect {
    const pos = top_left_pos.floored();
    const size_floored = size.floored();
    return .{
        .x = @intFromFloat(pos.x),
        .y = @intFromFloat(pos.y),
        .w = @intFromFloat(size_floored.x),
        .h = @intFromFloat(size_floored.y),
    };
}

/// Linearly interpolates between `start` and `end` by `t`.
fn lerp(start: f32, end: f32, t: f32) f32 {
    return (1.0 - t) * start + t * end;
}

fn lerp_clamped(start: f32, end: f32, t: f32) f32 {
    return lerp(start, end, math.clamp(t, 0.0, 1.0));
}

fn ilerp(start: f32, end: f32, value: f32) f32 {
    return (value - start) / (end - start);
}

fn ilerp_clamped(start: f32, end: f32, value: f32) f32 {
    return math.clamp(ilerp(start, end, value), 0.0, 1.0);
}

fn remap(
    start_in: f32,
    end_in: f32,
    start_out: f32,
    end_out: f32,
    value: f32,
) f32 {
    return lerp(start_out, end_out, ilerp(start_in, end_in, value));
}

fn remap_clamped(
    start_in: f32,
    end_in: f32,
    start_out: f32,
    end_out: f32,
    value: f32,
) f32 {
    return lerp(start_out, end_out, ilerp_clamped(start_in, end_in, value));
}

// To allow skipping rendering if flashing, or if any parent is flashing.
//
// We should probably make the sprites half opacity instead of turning them off when
// flashing for a less jarring effect, but that is difficult right now.
fn flash_off(entities: *const Entities, entity: EntityHandle) bool {
    var parent_it = parenting.iterator(entities, entity);
    while (parent_it.next()) |current| {
        if (entities.getComponent(current, .health)) |health| {
            if (health.invulnerable_s > 0.0) {
                var flashes_ps: f32 = 2;
                if (health.invulnerable_s < 0.25 * std.math.round(Health.max_invulnerable_s * flashes_ps) / flashes_ps) {
                    flashes_ps = 4;
                }
                if (std.math.sin(flashes_ps * std.math.tau * health.invulnerable_s) > 0.0) {
                    return true;
                }
            }
        }
    }
    return false;
}

test {
    _ = @import("asset_indexer.zig");
    _ = @import("slot_map.zig");
    _ = @import("minimum_alignment_allocator.zig");
    _ = ecs;
    _ = @import("segmented_list.zig");
    _ = @import("symmetric_matrix.zig");
}
