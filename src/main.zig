const std = @import("std");
const c = @import("c.zig");
const panic = std.debug.panic;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
const math = std.math;
const assert = std.debug.assert;
const V = @import("Vec2d.zig");
const ecs = @import("ecs/index.zig");
const FieldEnum = std.meta.FieldEnum;
const MinimumAlignmentAllocator = @import("minimum_alignment_allocator.zig").MinimumAlignmentAllocator;
const SymmetricMatrix = @import("symmetric_matrix.zig").SymmetricMatrix;

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
    .input = Input,
    .lifetime = Lifetime,
    .sprite = Sprite.Index,
    .animation = Animation.Playback,
    .collider = Collider,
    .turret = Turret,
    .grapple_gun = GrappleGun,
    .health = Health,
    .spring = Spring,
    .hook = Hook,
    .front_shield = struct {},
});
const PrefabEntity = ecs.entities.PrefabEntity(Entities);
const EntityHandle = ecs.entities.Handle;
const DeferredHandle = ecs.command_buffer.DeferredHandle;
const PrefabHandle = ecs.prefab.Handle;
const ComponentFlags = ecs.entities.ComponentFlags(Entities);
const CommandBuffer = ecs.command_buffer.CommandBuffer(Entities);
const parenting = ecs.parenting;

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
    const renderer: *c.SDL_Renderer = c.SDL_CreateRenderer(screen, -1, renderer_flags) orelse {
        panic("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyRenderer(renderer);

    // Load assets
    var assets = try Assets.init(gpa, renderer);
    defer assets.deinit();

    var game = try Game.init(&assets);

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
        render(assets, &entities, game, delta_s, fx_loop_s);

        // TODO(mason): we also want a min frame time so we don't get surprising floating point
        // results if it's too close to zero!
        // Adjust our expectd delta time a little every frame. We cap it at `max_frame_time` to
        // prevent e.g. a slow alt tab from messing things up too much.
        const delta_rwa_bias = 0.05;
        const max_frame_time = 1.0 / 30.0;
        var last_delta_s = @intToFloat(f32, timer.lap()) / std.time.ns_per_s;
        delta_s = lerp(delta_s, std.math.min(last_delta_s, max_frame_time), delta_rwa_bias);
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
        var it = entities.iterator(.{
            .input = .{ .mutable = true },
            .health = .{ .optional = true },
        });
        while (it.next()) |entity| {
            entity.input.update(&game.controllers);

            var parent_it = parenting.iterator(entities, it.handle());
            while (parent_it.next()) |current| {
                if (entities.getComponent(current, .health)) |health| {
                    if (health.invulnerable_s > 0.0) {
                        entity.input.state.getPtr(.fire).positive = .inactive;
                        break;
                    }
                }
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
                            shield_scale = std.math.max(dot, 0.0);
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
                            shield_scale = std.math.max(-dot, 0.0);
                        }
                        const damage = lerp(1.0, 1.0 - max_shield, std.math.pow(f32, shield_scale, 1.0 / 2.0)) * remap(20, 300, 0, 80, other_impulse.length());
                        if (damage >= 2) {
                            total_damage += other_health.damage(damage);
                        }
                    }
                }

                const shrapnel_amt = @floatToInt(
                    u32,
                    @floor(remap_clamped(0, 100, 0, 30, total_damage)),
                );
                const shrapnel_center = entity.transform.pos.plus(other.transform.pos).scaled(0.5);
                const avg_vel = entity.rb.vel.plus(other.rb.vel).scaled(0.5);
                for (0..shrapnel_amt) |_| {
                    const shrapnel_animation = game.shrapnel_animations[
                        std.crypto.random.uintLessThanBiased(usize, game.shrapnel_animations.len)
                    ];
                    // Spawn slightly off center from collision point.
                    const random_offset = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                        .scaled(std.crypto.random.float(f32) * 10);
                    // Give them random velocities.
                    const base_vel = if (std.crypto.random.boolean()) entity.rb.vel else other.rb.vel;
                    const random_vel = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                        .scaled(std.crypto.random.float(f32) * base_vel.length() * 2);
                    _ = command_buffer.appendInstantiate(true, &[_]PrefabEntity{
                        .{
                            .lifetime = .{
                                .seconds = 1.5 + std.crypto.random.float(f32) * 1.0,
                            },
                            .transform = .{
                                .pos = shrapnel_center.plus(random_offset),
                                .angle = 2 * math.pi * std.crypto.random.float(f32),
                            },
                            .rb = .{
                                .vel = avg_vel.plus(random_vel),
                                .rotation_vel = 2 * math.pi * std.crypto.random.float(f32),
                                .radius = game.animationRadius(shrapnel_animation),
                                .density = 0.001,
                            },
                            .animation = .{
                                .index = shrapnel_animation,
                                .destroys_entity = true,
                            },
                        },
                    });
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
                            .remove = ComponentFlags.initFromKinds(.{.hook}),
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
                            .remove = ComponentFlags.initFromKinds(.{.hook}),
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
    //         const x = std.math.max(delta.length() - entity.spring.length, 0.0);
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
                        // spawn shrapnel here
                        const shrapnel_animation = game.shrapnel_animations[
                            std.crypto.random.uintLessThanBiased(usize, game.shrapnel_animations.len)
                        ];
                        const random_vector = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                            .scaled(damage_entity.rb.vel.length() * 0.2);
                        _ = command_buffer.appendInstantiate(true, &[_]PrefabEntity{
                            .{
                                .lifetime = .{
                                    .seconds = 1.5 + std.crypto.random.float(f32) * 1.0,
                                },
                                .transform = .{
                                    .pos = health_entity.transform.pos,
                                    .angle = 2 * math.pi * std.crypto.random.float(f32),
                                },
                                .rb = .{
                                    .vel = health_entity.rb.vel.plus(damage_entity.rb.vel.scaled(0.2)).plus(random_vector),
                                    .rotation_vel = 2 * math.pi * std.crypto.random.float(f32),
                                    .radius = game.animationRadius(shrapnel_animation),
                                    .density = 0.001,
                                },
                                .animation = .{
                                    .index = shrapnel_animation,
                                    .destroys_entity = true,
                                },
                            },
                        });

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
            .ship = .{ .optional = true },
            .input = .{ .optional = true },
        });
        while (it.next()) |entity| {
            if (entity.health.hp <= 0) {
                // spawn explosion here
                if (entity.transform) |trans| {
                    _ = command_buffer.appendInstantiate(true, &[_]PrefabEntity{
                        .{
                            .lifetime = .{
                                .seconds = 100,
                            },
                            .transform = .{
                                .pos = trans.pos,
                            },
                            .rb = .{
                                .vel = if (entity.rb) |rb| rb.vel else .{ .x = 0, .y = 0 },
                                .rotation_vel = 0,
                                .radius = 32,
                                .density = 0.001,
                            },
                            .animation = .{
                                .index = game.explosion_animation,
                                .destroys_entity = true,
                            },
                        },
                    });
                }

                // If this is a player controlled ship, spawn a new ship for the player using this
                // ship's input before we destroy it!
                if (entity.ship) |ship| {
                    if (entity.input) |input| {
                        // give player their next ship
                        const player = &game.players[ship.player];
                        const team = &game.teams[player.team];
                        if (team.ship_progression_index >= team.ship_progression.len) {
                            const already_over = game.over();
                            team.players_alive -= 1;
                            if (game.over() and !already_over) {
                                const happy_team = game.aliveTeam();
                                game.spawnTeamVictory(entities, display_center, happy_team);
                            }
                        } else {
                            const new_angle = math.pi * 2 * std.crypto.random.float(f32);
                            const new_pos = display_center.plus(V.unit(new_angle).scaled(display_radius));
                            const facing_angle = new_angle + math.pi;
                            _ = game.createShip(command_buffer, ship.player, new_pos, facing_angle, input.*);
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
                entity.health.hp = std.math.min(entity.health.hp + regen_speed * delta_s, max_regen);
            }
            entity.health.regen_cooldown_s = std.math.max(entity.health.regen_cooldown_s - delta_s, 0.0);

            // Update invulnerability
            entity.health.invulnerable_s = std.math.max(entity.health.invulnerable_s - delta_s, 0.0);
        }
    }

    // Update ships
    {
        var it = entities.iterator(.{
            .ship = .{},
            .rb = .{ .mutable = true },
            .transform = .{ .mutable = true },
            .input = .{},
            .animation = .{ .optional = true, .mutable = true },
        });
        while (it.next()) |entity| {
            if (entity.ship.omnithrusters) {
                entity.rb.vel.add(.{
                    .x = entity.input.getAxis(.thrust_x) * entity.ship.thrust * delta_s,
                    .y = entity.input.getAxis(.thrust_y) * entity.ship.thrust * delta_s,
                });
            } else {
                // convert to 1.0 or 0.0
                entity.transform.angle = @mod(
                    entity.transform.angle + entity.input.getAxis(.turn) * entity.ship.turn_speed * delta_s,
                    2 * math.pi,
                );

                const thrust_input = @intToFloat(f32, @boolToInt(entity.input.isAction(.thrust_forward, .positive, .active)));
                const thrust = V.unit(entity.transform.angle);
                entity.rb.vel.add(thrust.scaled(thrust_input * entity.ship.thrust * delta_s));
            }
        }
    }

    // Update animate on input
    {
        var it = entities.iterator(.{
            .input = .{},
            .animate_on_input = .{},
            .animation = .{ .mutable = true },
        });
        while (it.next()) |entity| {
            if (entity.input.isAction(entity.animate_on_input.action, entity.animate_on_input.direction, .activated)) {
                entity.animation.* = .{
                    .index = entity.animate_on_input.activated,
                };
            } else if (entity.input.isAction(entity.animate_on_input.action, entity.animate_on_input.direction, .deactivated)) {
                entity.animation.* = .{
                    .index = entity.animate_on_input.deactivated,
                };
            }
        }
    }

    // TODO: break out cooldown logic or no?
    // Update grapple guns
    {
        var it = entities.iterator(.{
            .grapple_gun = .{ .mutable = true },
            .input = .{},
            .rb = .{},
            .transform = .{},
        });
        while (it.next()) |entity| {
            var gg = entity.grapple_gun;
            var input = entity.input;
            var rb = entity.rb;
            gg.cooldown_s -= delta_s;
            if (input.isAction(.fire, .positive, .activated) and gg.cooldown_s <= 0) {
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
                            // .sprite = game.bullet_small,
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
                        // .sprite = game.bullet_small,
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
        var it = entities.iterator(.{ .animation = .{} });
        while (it.next()) |entity| {
            if (entity.animation.destroys_entity and entity.animation.index == .none) {
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
            .input = .{},
            .rb = .{},
            .transform = .{},
        });
        while (it.next()) |entity| {
            var angle = entity.transform.angle_world_cached;
            var vel = V.unit(angle).scaled(entity.turret.projectile_speed).plus(entity.rb.vel);
            var sprite = game.bullet_small;
            if (entity.turret.aim_opposite_movement) {
                angle = entity.rb.vel.angle() + std.math.pi;
                vel = V.zero;
                sprite = game.bullet_shiny;
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
            if (entity.input.isAction(.fire, .positive, .active) and ready) {
                switch (entity.turret.cooldown) {
                    .time => |*time| time.current_s = time.max_s,
                    .distance => |*dist| dist.last_pos = fire_pos,
                }
                // TODO(mason): just make separate component for wall
                _ = command_buffer.appendInstantiate(true, &[_]PrefabEntity{
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
                        .sprite = sprite,
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
fn render(assets: Assets, entities: *Entities, game: Game, delta_s: f32, fx_loop_s: f32) void {
    const renderer = assets.renderer;

    // This was added for the flash effect and then not used since it already requires a timer
    // state. We'll be wanting it later and I don't feel like deleting and retyping the explanation
    // for it.
    _ = fx_loop_s;

    // Clear screen
    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0x00, 0x00, 0x00, 0xff));
    sdlAssertZero(c.SDL_RenderClear(renderer));

    // Draw stars
    for (game.stars) |star| {
        const sprite = assets.sprite(switch (star.kind) {
            .small => game.star_small,
            .large => game.star_large,
            .planet_red => game.planet_red,
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

    // Draw ring
    {
        const sprite = assets.sprite(game.ring_bg);
        sdlAssertZero(c.SDL_RenderCopy(
            renderer,
            sprite.texture,
            null,
            &sprite.toSdlRect(display_center),
        ));
    }

    // Draw animations
    {
        var it = entities.iterator(.{
            .rb = .{},
            .transform = .{},
            .animation = .{ .mutable = true },
            .health = .{ .optional = true },
            .ship = .{ .optional = true },
            .parent = .{ .optional = true },
        });
        draw: while (it.next()) |entity| {
            // Skip rendering if flashing, or if any parent is flashing.
            //
            // We should probably make the sprites half opacity instead of turning them off when
            // flashing for a less jarring effect, but that is difficult right now.
            {
                var curr: ?EntityHandle = it.handle();
                while (curr) |handle| {
                    if (entities.getComponent(handle, .health)) |health| {
                        if (health.invulnerable_s > 0.0) {
                            var flashes_ps: f32 = 2;
                            if (health.invulnerable_s < 0.25 * std.math.round(Health.max_invulnerable_s * flashes_ps) / flashes_ps) {
                                flashes_ps = 4;
                            }
                            if (std.math.sin(flashes_ps * std.math.tau * health.invulnerable_s) > 0.0) {
                                continue :draw;
                            }
                        }
                    }

                    if (entities.getComponent(handle, .parent)) |parent| {
                        curr = parent.*;
                    } else {
                        curr = null;
                    }
                }
            }

            if (entity.animation.index != .none) {
                const frame = assets.animate(entity.animation, delta_s);
                const unscaled_sprite_size = frame.sprite.size();
                const sprite_radius = (unscaled_sprite_size.x + unscaled_sprite_size.y) / 4.0;
                const size_coefficient = entity.rb.radius / sprite_radius;
                const sprite_size = unscaled_sprite_size.scaled(size_coefficient);
                var dest_rect = sdlRect(entity.transform.pos_world_cached.minus(sprite_size.scaled(0.5)), sprite_size);

                sdlAssertZero(c.SDL_RenderCopyEx(
                    renderer,
                    frame.sprite.texture,
                    null, // source rectangle
                    &dest_rect,
                    toDegrees(entity.transform.angle + frame.angle),
                    null, // center of angle
                    c.SDL_FLIP_NONE,
                ));

                if (entity.ship) |ship| {
                    const sprite = assets.sprite(game.team_sprites[game.players[ship.player].team]);
                    sdlAssertZero(c.SDL_RenderCopyEx(
                        renderer,
                        sprite.texture,
                        null, // source rectangle
                        &dest_rect,
                        0,
                        null, // center of angle
                        c.SDL_FLIP_NONE,
                    ));
                }
            }
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
                sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0xff, 0xff, 0xff, 0xff));
                sdlAssertZero(c.SDL_RenderFillRect(renderer, &sdlRect(
                    start.minus(.{ .x = 1, .y = 1 }),
                    health_bar_size.plus(.{ .x = 2, .y = 2 }),
                )));
                const hp_percent = entity.health.hp / entity.health.max_hp;
                if (hp_percent >= entity.health.regen_ratio) {
                    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0x00, 0x94, 0x13, 0xff));
                } else if (entity.health.regen_cooldown_s > 0.0) {
                    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0xe2, 0x00, 0x03, 0xff));
                } else {
                    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0xff, 0x7d, 0x03, 0xff));
                }
                sdlAssertZero(c.SDL_RenderFillRect(renderer, &sdlRect(
                    start,
                    .{ .x = health_bar_size.x * hp_percent, .y = health_bar_size.y },
                )));
            }
        }
    }

    // Draw sprites
    // TODO(mason): sort draw calls somehow (can the sdl renderer do depth buffers?)
    {
        var it = entities.iterator(.{ .sprite = .{}, .rb = .{}, .transform = .{} });
        while (it.next()) |entity| {
            const sprite = assets.sprite(entity.sprite.*);
            const unscaled_sprite_size = sprite.size();
            const sprite_radius = (unscaled_sprite_size.x + unscaled_sprite_size.y) / 4.0;
            const size_coefficient = entity.rb.radius / sprite_radius;
            const sprite_size = unscaled_sprite_size.scaled(size_coefficient);
            const dest_rect = sdlRect(entity.transform.pos.minus(sprite_size.scaled(0.5)), sprite_size);
            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer,
                sprite.texture,
                null, // source rectangle
                &dest_rect,
                toDegrees(entity.transform.angle),
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
            sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0xff, 0xff, 0xff, 0xff));
            sdlAssertZero(c.SDL_RenderDrawLine(
                renderer,
                @floatToInt(c_int, @floor(start.x)),
                @floatToInt(c_int, @floor(start.y)),
                @floatToInt(c_int, @floor(end.x)),
                @floatToInt(c_int, @floor(end.y)),
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
                const sprite = assets.sprite(game.team_sprites[team_index]);
                const pos = top_left.plus(.{
                    .x = col_width * @intToFloat(f32, team_index),
                    .y = 0,
                });
                sdlAssertZero(c.SDL_RenderCopy(
                    renderer,
                    sprite.texture,
                    null,
                    &sprite.toSdlRect(pos),
                ));
            }
            for (team.ship_progression, 0..) |class, display_prog_index| {
                const dead = team.ship_progression_index > display_prog_index;
                if (dead) continue;

                const sprite = assets.sprite(game.shipLifeSprite(class));
                const pos = top_left.plus(.{
                    .x = col_width * @intToFloat(f32, team_index),
                    .y = row_height * @intToFloat(f32, display_prog_index),
                });
                const sprite_size = sprite.size().scaled(0.5);
                const dest_rect = sdlRect(pos.minus(sprite_size.scaled(0.5)), sprite_size);
                sdlAssertZero(c.SDL_RenderCopy(
                    renderer,
                    sprite.texture,
                    null,
                    &dest_rect,
                ));
            }
        }
    }

    c.SDL_RenderPresent(renderer);
}

const Player = struct {
    team: u2,
};

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

const Input = struct {
    fn ActionMap(comptime T: type) type {
        return struct {
            turn: T,
            thrust_forward: T,
            thrust_x: T,
            thrust_y: T,
            fire: T,

            fn init(default: T) @This() {
                var map: @This() = undefined;
                inline for (@typeInfo(@This()).Struct.fields) |field| {
                    @field(map, field.name) = default;
                }
                return map;
            }
        };
    }

    pub const Action = FieldEnum(ActionMap(void));

    pub const KeyboardMap = ActionMap(struct {
        positive: ?u16 = null,
        negative: ?u16 = null,
    });

    pub const ControllerMap = ActionMap(struct {
        axis: ?c.SDL_GameControllerAxis = null,
        buttons: struct {
            positive: ?c.SDL_GameControllerButton = null,
            negative: ?c.SDL_GameControllerButton = null,
        } = .{},
        dead_zone: i16 = 10000,
    });

    pub const Direction = enum { positive, negative };
    pub const DirectionState = enum { active, activated, inactive, deactivated };

    const ActionState = struct {
        positive: DirectionState = .inactive,
        negative: DirectionState = .inactive,
    };

    controller_index: usize,
    controller_map: ControllerMap,
    keyboard_map: KeyboardMap,
    state: std.EnumArray(Action, ActionState) = std.EnumArray(Action, ActionState).initFill(.{}),

    pub fn update(self: *@This(), controllers: []?*c.SDL_GameController) void {
        inline for (comptime std.meta.tags(Action)) |action| {
            inline for (.{ Direction.positive, Direction.negative }) |direction| {
                // Check if the keyboard or controller control is activated
                const keyboard_action = @field(self.keyboard_map, @tagName(action));
                const key = if (@field(keyboard_action, @tagName(direction))) |key|
                    c.SDL_GetKeyboardState(null)[key] == 1
                else
                    false;

                const controller_action = @field(self.controller_map, @tagName(action));
                const button = if (@field(controller_action.buttons, @tagName(direction))) |button|
                    c.SDL_GameControllerGetButton(controllers[self.controller_index], button) != 0
                else
                    false;

                const axis = if (controller_action.axis) |axis| a: {
                    const v = c.SDL_GameControllerGetAxis(controllers[self.controller_index], axis);
                    switch (direction) {
                        .positive => break :a v > controller_action.dead_zone,
                        .negative => break :a v < -controller_action.dead_zone,
                    }
                } else false;

                // Update the current state
                const current_state = &@field(self.state.getPtr(action), @tagName(direction));

                if (key or button or axis) {
                    switch (current_state.*) {
                        .active, .activated => current_state.* = .active,
                        .inactive, .deactivated => current_state.* = .activated,
                    }
                } else {
                    switch (current_state.*) {
                        .active, .activated => current_state.* = .deactivated,
                        .inactive, .deactivated => current_state.* = .inactive,
                    }
                }
            }
        }
    }

    pub fn isAction(
        self: *const @This(),
        action: Action,
        direction: Direction,
        state: DirectionState,
    ) bool {
        const current_state = switch (direction) {
            .positive => self.state.get(action).positive,
            .negative => self.state.get(action).negative,
        };
        return switch (state) {
            .active => current_state == .active or current_state == .activated,
            .activated => current_state == .activated,
            .inactive => current_state == .inactive or current_state == .deactivated,
            .deactivated => current_state == .deactivated,
        };
    }

    pub fn getAxis(self: *const @This(), action: Action) f32 {
        // TODO(mason): make most recent input take precedence on keyboard?
        return @intToFloat(f32, @boolToInt(self.isAction(action, .positive, .active))) -
            @intToFloat(f32, @boolToInt(self.isAction(action, .negative, .active)));
    }
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
    action: Input.Action,
    direction: Input.Direction,
    activated: Animation.Index,
    deactivated: Animation.Index,
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
    player: u2,

    const Class = enum {
        ranger,
        militia,
        triangle,
        kevin,
        wendy,
    };
};

const Sprite = struct {
    texture: *c.SDL_Texture,
    rect: c.SDL_Rect,

    /// Index into the sprites array.
    const Index = enum(u32) {
        _,
    };

    /// Assumes the pos points to the center of the sprite.
    fn toSdlRect(sprite: Sprite, pos: V) c.SDL_Rect {
        const sprite_size = sprite.size();
        return sdlRect(pos.minus(sprite_size.scaled(0.5)), sprite_size);
    }

    fn size(sprite: Sprite) V {
        return .{
            .x = @intToFloat(f32, sprite.rect.w),
            .y = @intToFloat(f32, sprite.rect.h),
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

    players_buffer: [4]Player,
    controllers: [4]?*c.SDL_GameController = [_]?*c.SDL_GameController{ null, null, null, null },
    players: []Player,
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

    team_sprites: [4]Sprite.Index,

    const ShipAnimations = struct {
        still: Animation.Index,
        accel: Animation.Index,
        thrusters_left: ?Animation.Index = null,
        thrusters_right: ?Animation.Index = null,
        thrusters_top: ?Animation.Index = null,
        thrusters_bottom: ?Animation.Index = null,
    };

    const shrapnel_sprite_names = [_][]const u8{
        "img/shrapnel/01.png",
        "img/shrapnel/02.png",
        "img/shrapnel/03.png",
    };

    const rock_sprite_names = [_][]const u8{
        "img/rock-a.png",
        "img/rock-b.png",
        "img/rock-c.png",
    };

    fn createRanger(
        self: *const @This(),
        command_buffer: *CommandBuffer,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) PrefabHandle {
        return command_buffer.appendInstantiate(true, &[_]PrefabEntity{
            .{
                .ship = .{
                    .class = .ranger,
                    .turn_speed = math.pi * 1.0,
                    .thrust = 160,
                    .player = player_index,
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
                    .radius = self.ranger_radius,
                    .rotation_vel = 0.0,
                    .density = 0.02,
                },
                .collider = .{
                    .collision_damping = 0.4,
                    .layer = .vehicle,
                },
                .animation = .{
                    .index = self.ranger_animations.still,
                },
                .animate_on_input = .{
                    .action = .thrust_forward,
                    .direction = .positive,
                    .activated = self.ranger_animations.accel,
                    .deactivated = self.ranger_animations.still,
                },
                .turret = .{
                    .angle = 0,
                    .radius = self.ranger_radius,
                    .cooldown = .{ .time = .{ .max_s = 0.1 } },
                    .projectile_speed = 550,
                    .projectile_lifetime = 1.0,
                    .projectile_damage = 6,
                    .projectile_radius = 8,
                },
                .input = input,
            },
        });
    }

    fn createTriangle(
        self: *const @This(),
        command_buffer: *CommandBuffer,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) PrefabHandle {
        const radius = 24;
        return command_buffer.appendInstantiate(true, &[_]PrefabEntity{
            .{
                .ship = .{
                    .class = .triangle,
                    .turn_speed = math.pi * 0.9,
                    .thrust = 250,
                    .player = player_index,
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
                .animation = .{
                    .index = self.triangle_animations.still,
                },
                .animate_on_input = .{
                    .action = .thrust_forward,
                    .direction = .positive,
                    .activated = self.triangle_animations.accel,
                    .deactivated = self.triangle_animations.still,
                },
                .turret = .{
                    .angle = 0,
                    .radius = radius,
                    .cooldown = .{ .time = .{ .max_s = 0.2 } },
                    .projectile_speed = 700,
                    .projectile_lifetime = 1.0,
                    .projectile_damage = 12,
                    .projectile_radius = 12,
                },
                .input = input,
            },
        });
    }

    fn createMilitia(
        self: *const @This(),
        command_buffer: *CommandBuffer,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) PrefabHandle {
        return command_buffer.appendInstantiate(true, &[_]PrefabEntity{
            .{
                .ship = .{
                    .class = .militia,
                    .turn_speed = math.pi * 1.4,
                    .thrust = 400,
                    .player = player_index,
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
                    .radius = self.militia_radius,
                    .density = 0.06,
                },
                .collider = .{
                    .collision_damping = 0.4,
                    .layer = .vehicle,
                },
                .animation = .{
                    .index = self.militia_animations.still,
                },
                .animate_on_input = .{
                    .action = .thrust_forward,
                    .direction = .positive,
                    .activated = self.militia_animations.accel,
                    .deactivated = self.militia_animations.still,
                },
                // .grapple_gun = .{
                //     .radius = self.ranger_radius * 10.0,
                //     .angle = 0,
                //     .cooldown_s = 0,
                //     .max_cooldown_s = 0.2,
                //     // TODO: when nonzero, causes the ship to move. wouldn't happen if there was equal
                //     // kickback!
                //     .projectile_speed = 0,
                // },
                .input = input,
                .front_shield = .{},
            },
        });
    }

    // XXX: make sure this still works!
    fn createKevin(
        self: *const @This(),
        command_buffer: *CommandBuffer,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) PrefabHandle {
        const ship_handle = PrefabHandle.init(0);

        const radius = 32;
        return command_buffer.appendInstantiate(true, &[_]PrefabEntity{
            .{
                .ship = .{
                    .class = .kevin,
                    .turn_speed = math.pi * 1.1,
                    .thrust = 300,
                    .player = player_index,
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
                .animation = .{
                    .index = self.kevin_animations.still,
                },
                .animate_on_input = .{
                    .action = .thrust_forward,
                    .direction = .positive,
                    .activated = self.kevin_animations.accel,
                    .deactivated = self.kevin_animations.still,
                },
                .input = input,
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
                .input = input,
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
                .input = input,
                .rb = .{
                    .radius = radius,
                    .density = std.math.inf(f32),
                },
                .transform = .{},
            },
        });
    }

    fn createWendy(
        self: *const @This(),
        command_buffer: *CommandBuffer,
        player_index: u2,
        pos: V,
        _: f32,
        input: Input,
    ) PrefabHandle {
        // XXX: don't let us instantiate prefabs that create infinite loops of entities somehow? or at least catch it
        // and crash or break the loop etc
        // XXX: make a fancier helper that lets us like, spawn a bunch of handles, and then set each one at
        // a time, to avoid getting handles mixed up? Or any other nice way to do this? There may also be some
        // comptime transformation we can do that makes this possible with a less error prone sytnax etc. The data
        // doesn't have ot be comptime just the transformation of pointers or whatever idk.
        // XXX: cast...
        // const ship_handle = PrefabHandle.init(@intCast(u20, command_buffer.prefab_entities.items.len));
        const ship_handle = PrefabHandle.init(0);
        return command_buffer.appendInstantiate(true, &[_]PrefabEntity{
            .{
                .ship = .{
                    .class = .wendy,
                    .turn_speed = math.pi * 1.0,
                    .thrust = 200,
                    .player = player_index,
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
                    .radius = self.wendy_radius,
                    .rotation_vel = 0.0,
                    .density = 0.02,
                },
                .collider = .{
                    .collision_damping = 0.4,
                    .layer = .vehicle,
                },
                .animation = .{
                    .index = self.wendy_animations.still,
                },
                .turret = .{
                    .radius = self.wendy_radius,
                    .angle = 0,
                    .cooldown = .{ .distance = .{ .min_sq = std.math.pow(f32, 10.0, 2.0) } },
                    .projectile_speed = 0,
                    .projectile_lifetime = 5.0,
                    .projectile_damage = 50,
                    .projectile_radius = 8,
                    .projectile_density = std.math.inf(f32),
                    .aim_opposite_movement = true,
                },
                .input = input,
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = self.wendy_radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_y,
                    .direction = .positive,
                    .activated = self.wendy_animations.thrusters_left.?,
                    .deactivated = .none,
                },
                .animation = .{
                    .index = .none,
                },
                .input = input,
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = self.wendy_radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_y,
                    .direction = .negative,
                    .activated = self.wendy_animations.thrusters_right.?,
                    .deactivated = .none,
                },
                .animation = .{
                    .index = .none,
                },
                .input = input,
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = self.wendy_radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_x,
                    .direction = .negative,
                    .activated = self.wendy_animations.thrusters_top.?,
                    .deactivated = .none,
                },
                .animation = .{
                    .index = .none,
                },
                .input = input,
            },
            .{
                .parent = ship_handle.relative,
                .transform = .{},
                .rb = .{
                    .radius = self.wendy_radius,
                    .density = std.math.inf(f32),
                },
                .animate_on_input = .{
                    .action = .thrust_x,
                    .direction = .positive,
                    .activated = self.wendy_animations.thrusters_bottom.?,
                    .deactivated = .none,
                },
                .animation = .{
                    .index = .none,
                },
                .input = input,
            },
        });
    }

    fn init(assets: *Assets) !Game {
        const ring_bg = try assets.loadSprite("img/ring.png");
        const star_small = try assets.loadSprite("img/star/small.png");
        const star_large = try assets.loadSprite("img/star/large.png");
        const planet_red = try assets.loadSprite("img/planet-red.png");
        const bullet_small = try assets.loadSprite("img/bullet/small.png");
        const bullet_shiny = try assets.loadSprite("img/bullet/shiny.png");

        var shrapnel_sprites: [shrapnel_sprite_names.len]Sprite.Index = undefined;
        for (&shrapnel_sprites, shrapnel_sprite_names) |*s, name| {
            s.* = try assets.loadSprite(name);
        }

        var rock_sprites: [rock_sprite_names.len]Sprite.Index = undefined;
        for (&rock_sprites, rock_sprite_names) |*s, name| {
            s.* = try assets.loadSprite(name);
        }

        const shrapnel_animations: [shrapnel_sprites.len]Animation.Index = .{
            try assets.addAnimation(&.{shrapnel_sprites[0]}, null, 30, 0.0),
            try assets.addAnimation(&.{shrapnel_sprites[1]}, null, 30, 0.0),
            try assets.addAnimation(&.{shrapnel_sprites[2]}, null, 30, 0.0),
        };

        const ranger_sprites = [_]Sprite.Index{
            try assets.loadSprite("img/ship/ranger0.png"),
            try assets.loadSprite("img/ship/ranger1.png"),
            try assets.loadSprite("img/ship/ranger2.png"),
            try assets.loadSprite("img/ship/ranger3.png"),
        };
        const ranger_still = try assets.addAnimation(&.{
            ranger_sprites[0],
        }, null, 30, math.pi / 2.0);
        const ranger_steady_thrust = try assets.addAnimation(&.{
            ranger_sprites[2],
            ranger_sprites[3],
        }, null, 10, math.pi / 2.0);
        const ranger_accel = try assets.addAnimation(&.{
            ranger_sprites[1],
        }, ranger_steady_thrust, 10, math.pi / 2.0);

        const militia_sprites = [_]Sprite.Index{
            try assets.loadSprite("img/ship/militia0.png"),
            try assets.loadSprite("img/ship/militia1.png"),
            try assets.loadSprite("img/ship/militia2.png"),
            try assets.loadSprite("img/ship/militia3.png"),
        };
        const militia_still = try assets.addAnimation(&.{
            militia_sprites[0],
        }, null, 30, math.pi / 2.0);
        const militia_steady_thrust = try assets.addAnimation(&.{
            militia_sprites[2],
            militia_sprites[3],
        }, null, 10, math.pi / 2.0);
        const militia_accel = try assets.addAnimation(&.{
            militia_sprites[1],
        }, militia_steady_thrust, 10, math.pi / 2.0);

        const explosion_animation = try assets.addAnimation(&.{
            try assets.loadSprite("img/explosion/01.png"),
            try assets.loadSprite("img/explosion/02.png"),
            try assets.loadSprite("img/explosion/03.png"),
            try assets.loadSprite("img/explosion/04.png"),
            try assets.loadSprite("img/explosion/05.png"),
            try assets.loadSprite("img/explosion/06.png"),
            try assets.loadSprite("img/explosion/07.png"),
            try assets.loadSprite("img/explosion/08.png"),
            try assets.loadSprite("img/explosion/09.png"),
            try assets.loadSprite("img/explosion/10.png"),
            try assets.loadSprite("img/explosion/11.png"),
            try assets.loadSprite("img/explosion/12.png"),
        }, .none, 30, 0.0);

        const triangle_sprites = [_]Sprite.Index{
            try assets.loadSprite("img/ship/triangle0.png"),
            try assets.loadSprite("img/ship/triangle1.png"),
            try assets.loadSprite("img/ship/triangle2.png"),
            try assets.loadSprite("img/ship/triangle3.png"),
        };
        const triangle_still = try assets.addAnimation(&.{
            triangle_sprites[0],
        }, null, 30, math.pi / 2.0);
        const triangle_steady_thrust = try assets.addAnimation(&.{
            triangle_sprites[2],
            triangle_sprites[3],
        }, null, 10, math.pi / 2.0);
        const triangle_accel = try assets.addAnimation(&.{
            triangle_sprites[1],
        }, triangle_steady_thrust, 10, math.pi / 2.0);

        const kevin_sprites = [_]Sprite.Index{
            try assets.loadSprite("img/ship/kevin0.png"),
            try assets.loadSprite("img/ship/kevin1.png"),
            try assets.loadSprite("img/ship/kevin2.png"),
            try assets.loadSprite("img/ship/kevin3.png"),
        };
        const kevin_still = try assets.addAnimation(&.{
            kevin_sprites[0],
        }, null, 30, math.pi / 2.0);
        const kevin_steady_thrust = try assets.addAnimation(&.{
            kevin_sprites[2],
            kevin_sprites[3],
        }, null, 10, math.pi / 2.0);
        const kevin_accel = try assets.addAnimation(&.{
            kevin_sprites[1],
        }, kevin_steady_thrust, 10, math.pi / 2.0);

        const wendy_sprite = try assets.loadSprite("img/ship/wendy/ship.png");
        const wendy_thrusters_left = [_]Sprite.Index{
            try assets.loadSprite("img/ship/wendy/thrusters/left/0.png"),
            try assets.loadSprite("img/ship/wendy/thrusters/left/1.png"),
            try assets.loadSprite("img/ship/wendy/thrusters/left/2.png"),
        };
        const wendy_thrusters_right = [_]Sprite.Index{
            try assets.loadSprite("img/ship/wendy/thrusters/right/0.png"),
            try assets.loadSprite("img/ship/wendy/thrusters/right/1.png"),
            try assets.loadSprite("img/ship/wendy/thrusters/right/2.png"),
        };
        const wendy_thrusters_top = [_]Sprite.Index{
            try assets.loadSprite("img/ship/wendy/thrusters/top/0.png"),
            try assets.loadSprite("img/ship/wendy/thrusters/top/1.png"),
            try assets.loadSprite("img/ship/wendy/thrusters/top/2.png"),
        };
        const wendy_thrusters_bottom = [_]Sprite.Index{
            try assets.loadSprite("img/ship/wendy/thrusters/bottom/0.png"),
            try assets.loadSprite("img/ship/wendy/thrusters/bottom/1.png"),
            try assets.loadSprite("img/ship/wendy/thrusters/bottom/2.png"),
        };
        const wendy_still = try assets.addAnimation(&.{
            wendy_sprite,
        }, null, 30, math.pi / 2.0);
        const wendy_thrusters_left_steady = try assets.addAnimation(&.{
            wendy_thrusters_left[1],
            wendy_thrusters_left[2],
        }, null, 10, math.pi / 2.0);
        const wendy_thrusters_left_accel = try assets.addAnimation(&.{
            wendy_thrusters_left[0],
        }, wendy_thrusters_left_steady, 10, math.pi / 2.0);
        const wendy_thrusters_right_steady = try assets.addAnimation(&.{
            wendy_thrusters_right[1],
            wendy_thrusters_right[2],
        }, null, 10, math.pi / 2.0);
        const wendy_thrusters_right_accel = try assets.addAnimation(&.{
            wendy_thrusters_right[0],
        }, wendy_thrusters_right_steady, 10, math.pi / 2.0);
        const wendy_thrusters_top_steady = try assets.addAnimation(&.{
            wendy_thrusters_top[1],
            wendy_thrusters_top[2],
        }, null, 10, math.pi / 2.0);
        const wendy_thrusters_top_accel = try assets.addAnimation(&.{
            wendy_thrusters_top[0],
        }, wendy_thrusters_top_steady, 10, math.pi / 2.0);
        const wendy_thrusters_bottom_steady = try assets.addAnimation(&.{
            wendy_thrusters_bottom[1],
            wendy_thrusters_bottom[2],
        }, null, 10, math.pi / 2.0);
        const wendy_thrusters_bottom_accel = try assets.addAnimation(&.{
            wendy_thrusters_bottom[0],
        }, wendy_thrusters_bottom_steady, 10, math.pi / 2.0);

        const ranger_radius = @intToFloat(f32, assets.sprite(ranger_sprites[0]).rect.w) / 2.0;
        const militia_radius = @intToFloat(f32, assets.sprite(militia_sprites[0]).rect.w) / 2.0;
        const triangle_radius = @intToFloat(f32, assets.sprite(triangle_sprites[0]).rect.w) / 2.0;
        const kevin_radius = @intToFloat(f32, assets.sprite(triangle_sprites[0]).rect.w) / 2.0;
        const wendy_radius = @intToFloat(f32, assets.sprite(triangle_sprites[0]).rect.w) / 2.0;

        const team_sprites: [4]Sprite.Index = .{
            try assets.loadSprite("img/team0.png"),
            try assets.loadSprite("img/team1.png"),
            try assets.loadSprite("img/team2.png"),
            try assets.loadSprite("img/team3.png"),
        };

        return .{
            .assets = assets,
            .teams = undefined,
            .teams_buffer = undefined,
            .players = undefined,
            .players_buffer = undefined,
            .shrapnel_animations = shrapnel_animations,
            .explosion_animation = explosion_animation,

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

            .team_sprites = team_sprites,
        };
    }

    fn createShip(
        game: *Game,
        command_buffer: *CommandBuffer,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) PrefabHandle {
        const player = game.players[player_index];
        const team = &game.teams[player.team];
        const progression_index = team.ship_progression_index;
        team.ship_progression_index += 1;
        return switch (team.ship_progression[progression_index]) {
            .ranger => game.createRanger(command_buffer, player_index, pos, angle, input),
            .militia => game.createMilitia(command_buffer, player_index, pos, angle, input),
            .triangle => game.createTriangle(command_buffer, player_index, pos, angle, input),
            .kevin => game.createKevin(command_buffer, player_index, pos, angle, input),
            .wendy => game.createWendy(command_buffer, player_index, pos, angle, input),
        };
    }

    fn shipLifeSprite(game: Game, class: Ship.Class) Sprite.Index {
        const animation_index = switch (class) {
            .ranger => game.ranger_animations.still,
            .militia => game.militia_animations.still,
            .triangle => game.triangle_animations.still,
            .kevin => game.kevin_animations.still,
            .wendy => game.wendy_animations.still,
        };
        const animation = game.assets.animations.items[@enumToInt(animation_index)];
        const sprite_index = game.assets.frames.items[animation.start];
        return sprite_index;
    }

    fn animationRadius(game: Game, animation_index: Animation.Index) f32 {
        const assets = game.assets;
        const animation = assets.animations.items[@enumToInt(animation_index)];
        const sprite_index = assets.frames.items[animation.start];
        const sprite = assets.sprites.items[@enumToInt(sprite_index)];
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

    fn setupScenario(game: *Game, command_buffer: *CommandBuffer, scenario: Scenario) void {
        command_buffer.entities.clearRetainingCapacity();

        switch (scenario) {
            .deathmatch_2v2,
            .deathmatch_2v2_no_rocks,
            .deathmatch_2v2_one_rock,
            => {
                const progression = &.{
                    .wendy, // XXX: ...
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

                const players = game.players_buffer[0..4];
                players.* = .{
                    .{ .team = 0 },
                    .{ .team = 1 },
                    .{ .team = 0 },
                    .{ .team = 1 },
                };
                game.players = players;
            },

            .deathmatch_1v1, .deathmatch_1v1_one_rock => {
                const progression = &.{
                    .wendy, // XXX: ...
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

                const players = game.players_buffer[0..2];
                players.* = .{
                    .{ .team = 0 },
                    .{ .team = 1 },
                };
                game.players = players;
            },

            .royale_4p => {
                const progression = &.{
                    .wendy, // XXX: ...
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

                const players = game.players_buffer[0..4];
                players.* = .{
                    .{ .team = 0 },
                    .{ .team = 1 },
                    .{ .team = 2 },
                    .{ .team = 3 },
                };
                game.players = players;
            },
        }

        // Set up players
        {
            {
                var player_index: u32 = 0;
                for (0..@intCast(usize, c.SDL_NumJoysticks())) |i_usize| {
                    const i = @intCast(u31, i_usize);
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

            const controller_default = Input.ControllerMap{
                .turn = .{ .axis = c.SDL_CONTROLLER_AXIS_LEFTX },
                .thrust_forward = .{
                    .buttons = .{ .positive = c.SDL_CONTROLLER_BUTTON_B },
                },
                .thrust_x = .{ .axis = c.SDL_CONTROLLER_AXIS_LEFTX },
                .thrust_y = .{ .axis = c.SDL_CONTROLLER_AXIS_LEFTY },
                .fire = .{
                    .buttons = .{ .positive = c.SDL_CONTROLLER_BUTTON_A },
                },
            };
            const keyboard_wasd = Input.KeyboardMap{
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
            const keyboard_arrows = Input.KeyboardMap{
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
            const keyboard_none: Input.KeyboardMap = .{
                .turn = .{},
                .thrust_forward = .{},
                .thrust_x = .{},
                .thrust_y = .{},
                .fire = .{},
            };

            var input_devices = [_]Input{
                .{
                    .controller_index = 0,
                    .controller_map = controller_default,
                    .keyboard_map = keyboard_wasd,
                },
                .{
                    .controller_index = 1,
                    .controller_map = controller_default,
                    .keyboard_map = keyboard_arrows,
                },
                .{
                    .controller_index = 2,
                    .controller_map = controller_default,
                    .keyboard_map = keyboard_none,
                },
                .{
                    .controller_index = 3,
                    .controller_map = controller_default,
                    .keyboard_map = keyboard_none,
                },
            };

            for (game.players, input_devices[0..game.players.len], 0..) |_, input, i| {
                const angle = math.pi / 2.0 * @intToFloat(f32, i);
                const pos = display_center.plus(V.unit(angle).scaled(50));
                const player_index = @intCast(u2, i);
                _ = game.createShip(command_buffer, player_index, pos, angle, input);
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
            const sprite = game.rock_sprites[std.crypto.random.uintLessThanBiased(usize, game.rock_sprites.len)];
            const pos = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                .scaled(lerp(display_radius, display_radius * 1.1, std.crypto.random.float(f32)))
                .plus(display_center);

            _ = command_buffer.appendInstantiate(true, &[_]PrefabEntity{
                .{
                    .sprite = sprite,
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

    fn spawnTeamVictory(game: *Game, entities: *Entities, pos: V, team: u2) void {
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
                .sprite = game.team_sprites[team],
            });
        }
    }

    fn aliveTeam(game: Game) u2 {
        for (game.teams, 0..) |team, i| {
            if (team.players_alive > 0) return @intCast(u2, i);
        } else unreachable;
    }

    fn aliveTeamCount(game: Game) u32 {
        var count: u32 = 0;
        for (game.teams) |team| {
            count += @boolToInt(team.players_alive > 0);
        }
        return count;
    }

    fn over(game: Game) bool {
        return game.aliveTeamCount() <= 1;
    }
};

const Assets = struct {
    gpa: Allocator,
    renderer: *c.SDL_Renderer,
    dir: std.fs.Dir,
    sprites: std.ArrayListUnmanaged(Sprite),
    frames: std.ArrayListUnmanaged(Sprite.Index),
    animations: std.ArrayListUnmanaged(Animation),

    const Frame = struct {
        sprite: Sprite,
        angle: f32,
    };

    fn init(gpa: Allocator, renderer: *c.SDL_Renderer) !Assets {
        const self_exe_dir_path = try std.fs.selfExeDirPathAlloc(gpa);
        defer gpa.free(self_exe_dir_path);
        const assets_dir_path = try std.fs.path.join(gpa, &.{ self_exe_dir_path, "data" });
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
            .frames = .{},
            .animations = .{},
        };
    }

    fn deinit(a: *Assets) void {
        a.dir.close();
        a.sprites.deinit(a.gpa);
        a.frames.deinit(a.gpa);
        a.animations.deinit(a.gpa);
        a.* = undefined;
    }

    fn animate(a: Assets, anim: *Animation.Playback, delta_s: f32) Frame {
        const animation = a.animations.items[@enumToInt(anim.index)];
        const frame_index = @floatToInt(u32, @floor(anim.time_passed * animation.fps));
        const frame = animation.start + frame_index;
        // TODO: for large delta_s can cause out of bounds index
        const frame_sprite = a.sprite(a.frames.items[frame]);
        anim.time_passed += delta_s;
        const end_time = @intToFloat(f32, animation.len) / animation.fps;
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
        const result = @intToEnum(Animation.Index, a.animations.items.len);
        try a.animations.append(a.gpa, .{
            .start = @intCast(u32, a.frames.items.len - frames.len),
            .len = @intCast(u32, frames.len),
            .next = next_animation orelse result,
            .fps = fps,
            .angle = angle,
        });
        return result;
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

    const Kind = enum { large, small, planet_red };
};

fn generateStars(stars: []Star) void {
    for (stars) |*star| {
        star.* = .{
            .x = std.crypto.random.uintLessThanBiased(u31, display_width),
            .y = std.crypto.random.uintLessThanBiased(u31, display_height),
            .kind = @intToEnum(Star.Kind, std.crypto.random.uintLessThanBiased(u8, 2)),
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
        .x = @floatToInt(i32, pos.x),
        .y = @floatToInt(i32, pos.y),
        .w = @floatToInt(i32, size_floored.x),
        .h = @floatToInt(i32, size_floored.y),
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

test {
    _ = @import("slot_map.zig");
    _ = @import("minimum_alignment_allocator.zig");
    _ = ecs;
    _ = @import("segmented_list.zig");
    _ = @import("symmetric_matrix.zig");
}
