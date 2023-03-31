const std = @import("std");
const c = @import("c.zig");
const panic = std.debug.panic;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const math = std.math;
const V = @import("Vec2d.zig");
const FieldEnum = std.meta.FieldEnum;
const MinimumAlignmentAllocator = @import("minimum_alignment_allocator.zig").MinimumAlignmentAllocator;

const display_width = 1920;
const display_height = 1080;
const display_center: V = .{
    .x = display_width / 2.0,
    .y = display_height / 2.0,
};
const display_radius = display_height / 2.0;

const ecs = @import("ecs.zig");
const Entities = ecs.Entities(.{
    .damage = Damage,
    .ship = Ship,
    .rb = RigidBody,
    .input = Input,
    .lifetime = Lifetime,
    .sprite = Sprite.Index,
    .animation = Animation.Playback,
    .collider = Collider,
    .turrets = [2]Turret,
    .grapple_gun = GrappleGun,
    .health = Health,
    .spring = Spring,
    .hook = Hook,
    .front_shield = struct {},
});
const EntityHandle = Entities.Handle;

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
    var buffer = try pa.alloc(u8, ecs.max_entities * 1024);
    defer pa.free(buffer);
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    var maa = MinimumAlignmentAllocator(64).init(fba.allocator());
    var entities = try Entities.init(maa.allocator());
    defer entities.deinit();

    game.setupScenario(&entities, .deathmatch_2v2);

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
        if (poll(&entities, &game)) return;
        update(&entities, &game, delta_s);
        render(assets, &entities, game, delta_s, fx_loop_s);

        // TODO(mason): we also want a min frame time so we don't get supririsng floating point
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

fn poll(entities: *Entities, game: *Game) bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        switch (event.type) {
            c.SDL_QUIT => return true,
            c.SDL_KEYDOWN => switch (event.key.keysym.scancode) {
                c.SDL_SCANCODE_ESCAPE => return true,
                c.SDL_SCANCODE_1 => {
                    game.setupScenario(entities, .deathmatch_2v2);
                },
                c.SDL_SCANCODE_2 => {
                    game.setupScenario(entities, .deathmatch_2v2_no_rocks);
                },
                c.SDL_SCANCODE_3 => {
                    game.setupScenario(entities, .deathmatch_2v2_one_rock);
                },
                c.SDL_SCANCODE_4 => {
                    game.setupScenario(entities, .deathmatch_1v1);
                },
                c.SDL_SCANCODE_5 => {
                    game.setupScenario(entities, .deathmatch_1v1_one_rock);
                },
                c.SDL_SCANCODE_6 => {
                    game.setupScenario(entities, .royale_4p);
                },
                else => {},
            },
            else => {},
        }
    }
    return false;
}

fn update(entities: *Entities, game: *Game, delta_s: f32) void {
    // Update input
    {
        var it = entities.iterator(.{.input});
        while (it.next()) |entity| {
            entity.comps.input.update();

            if (entities.getComponent(entity.handle, .health)) |health| {
                if (health.invulnerable_s > 0.0) {
                    entity.comps.input.state.fire.positive = .inactive;
                }
            }
        }
    }

    // Update ship animations
    {
        var it = entities.iterator(.{ .ship, .animation, .input });
        while (it.next()) |entity| {
            const ship = entity.comps.ship;
            const animation = entity.comps.animation;
            const input = entity.comps.input;
            if (input.isAction(.thrust_forward, .positive, .activated)) {
                // TODO(mason): do initialziers that reference the thing they're being set on still
                // need to be on separate lines? (this doesn't do that anymore either way)
                animation.* = .{
                    .index = ship.accel,
                    .time_passed = 0,
                };
            } else if (input.isAction(.thrust_forward, .positive, .deactivated)) {
                animation.* = .{
                    .index = ship.still,
                    .time_passed = 0,
                };
            }
        }
    }

    // Update collisions
    {
        var it = entities.iterator(.{ .rb, .collider });
        while (it.next()) |entity| {
            const rb = entity.comps.rb;
            const collider = entity.comps.collider;

            // bonk
            var other_it = it;
            while (other_it.next()) |other_entity| {
                const other = other_entity.comps;

                if (!Collider.interacts.get(collider.layer, other.collider.layer)) continue;

                const added_radii = rb.radius + other.rb.radius;
                if (rb.pos.distanceSqrd(other.rb.pos) > added_radii * added_radii) continue;

                // calculate normal
                const normal = other.rb.pos.minus(rb.pos).normalized();
                // calculate relative velocity
                const rv = other.rb.vel.minus(rb.vel);
                // calculate relative velocity in terms of the normal direction
                const vel_along_normal = rv.dot(normal);
                // do not resolve if velocities are separating
                if (vel_along_normal > 0) continue;
                // calculate restitution
                const e = @min(collider.collision_damping, other.collider.collision_damping);
                // calculate impulse scalar
                var j: f32 = -(1.0 + e) * vel_along_normal;
                const my_mass = rb.mass();
                const other_mass = other.rb.mass();
                j /= 1.0 / my_mass + 1.0 / other_mass;
                // apply impulse
                const impulse_mag = normal.scaled(j);
                const impulse = impulse_mag.scaled(1 / my_mass);
                const other_impulse = impulse_mag.scaled(1 / other_mass);
                rb.vel.sub(impulse);
                other.rb.vel.add(other_impulse);

                // Deal HP damage relative to the change in velocity.
                // A very gentle bonk is something like impulse 20, while a
                // very hard bonk is around 300.
                // The basic ranger ship has 80 HP.
                var total_damage: f32 = 0;
                const max_shield = 1.0;
                const entity_health = entities.getComponent(entity.handle, .health);
                const other_health = entities.getComponent(other_entity.handle, .health);
                if (entity_health) |health| {
                    if (other_health == null or other_health.?.invulnerable_s <= 0.0) {
                        var shield_scale: f32 = 0.0;
                        if (entities.getComponent(entity.handle, .front_shield) != null) {
                            var dot = V.unit(rb.angle).dot(normal);
                            shield_scale = std.math.max(dot, 0.0);
                        }
                        const damage = lerp(1.0, 1.0 - max_shield, std.math.pow(f32, shield_scale, 1.0 / 2.0)) * remap(20, 300, 0, 80, impulse.length());
                        if (damage >= 2) {
                            total_damage += health.damage(damage);
                        }
                    }
                }
                if (other_health) |health| {
                    if (entity_health == null or entity_health.?.invulnerable_s <= 0.0) {
                        var shield_scale: f32 = 0.0;
                        if (entities.getComponent(entity.handle, .front_shield) != null) {
                            var dot = V.unit(other.rb.angle).dot(normal);
                            shield_scale = std.math.max(-dot, 0.0);
                        }
                        const damage = lerp(1.0, 1.0 - max_shield, std.math.pow(f32, shield_scale, 1.0 / 2.0)) * remap(20, 300, 0, 80, other_impulse.length());
                        if (damage >= 2) {
                            total_damage += health.damage(damage);
                        }
                    }
                }

                const shrapnel_amt = @floatToInt(
                    u32,
                    @floor(remap_clamped(0, 100, 0, 30, total_damage)),
                );
                const shrapnel_center = rb.pos.plus(other.rb.pos).scaled(0.5);
                const avg_vel = rb.vel.plus(other.rb.vel).scaled(0.5);
                for (0..shrapnel_amt) |_| {
                    const shrapnel_animation = game.shrapnel_animations[
                        std.crypto.random.uintLessThanBiased(usize, game.shrapnel_animations.len)
                    ];
                    // Spawn slightly off center from collision point.
                    const random_offset = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                        .scaled(std.crypto.random.float(f32) * 10);
                    // Give them random velocities.
                    const base_vel = if (std.crypto.random.boolean()) rb.vel else other.rb.vel;
                    const random_vel = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                        .scaled(std.crypto.random.float(f32) * base_vel.length() * 2);
                    _ = entities.create(.{
                        .lifetime = .{
                            .seconds = 1.5 + std.crypto.random.float(f32) * 1.0,
                        },
                        .rb = .{
                            .pos = shrapnel_center.plus(random_offset),
                            .vel = avg_vel.plus(random_vel),
                            .angle = 2 * math.pi * std.crypto.random.float(f32),
                            .rotation_vel = 2 * math.pi * std.crypto.random.float(f32),
                            .radius = game.animationRadius(shrapnel_animation),
                            .density = 0.001,
                        },
                        .animation = .{
                            .index = shrapnel_animation,
                            .time_passed = 0,
                            .destroys_entity = true,
                        },
                    });
                }

                // XXX: adding/removing components here reorders things and could cause this to be run again...
                // could do before collision, just check hooks against rbs and start over every time or something
                // XXX: why does it fly away when attached? well partly it's that i set the distance to 0 when
                // the current distance is greater...fixing that
                // XXX: don't always attach to the center? this is easy to do, but, it won't cause
                // rotation the way you'd expect at the moment since the current physics system doesn't
                // have opinions on rotation. We can add that though!
                {
                    var hooked = false;
                    if (entities.getComponent(entity.handle, .hook)) |hook| {
                        // XXX: make a public changeArchetype function so that we can do this in a single
                        // move, could also be named removeComponentsAddComponents or such, probably
                        // should work even if overlap?
                        entities.removeComponents(entity.handle, .{.hook});
                        entities.addComponents(entity.handle, .{ .spring = Spring{
                            .start = entity.handle,
                            .end = other_entity.handle,
                            .k = hook.k,
                            .length = rb.pos.distance(other.rb.pos),
                            .damping = hook.damping,
                        } });
                        hooked = true;
                    }
                    if (entities.getComponent(other_entity.handle, .hook)) |hook| {
                        entities.removeComponents(other_entity.handle, .{.hook});
                        entities.addComponents(other_entity.handle, .{ .spring = Spring{
                            .start = entity.handle,
                            .end = other_entity.handle,
                            .k = hook.k,
                            .length = rb.pos.distance(other.rb.pos),
                            .damping = hook.damping,
                        } });
                        hooked = true;
                    }
                    // XXX: continue afte first one..?
                    if (hooked) {
                        continue;
                    }
                }
            }
        }
    }

    // Update rbs
    {
        var it = entities.iterator(.{.rb});
        while (it.next()) |entity| {
            const rb = entity.comps.rb;
            rb.pos.add(rb.vel.scaled(delta_s));

            // gravity if the rb is outside the ring
            if (rb.pos.distanceSqrd(display_center) > display_radius * display_radius) {
                const gravity = 500;
                const gravity_v = display_center.minus(rb.pos).normalized().scaled(gravity * delta_s);
                rb.vel.add(gravity_v);
                if (entities.getComponent(entity.handle, .health)) |health| {
                    // punishment for leaving the circle
                    _ = health.damage(delta_s * 4);
                }
            }

            rb.angle = @mod(
                rb.angle + rb.rotation_vel * delta_s,
                2 * math.pi,
            );
        }
    }

    // Update springs
    {
        var it = entities.iterator(.{.spring});
        while (it.next()) |entity| {
            const spring = entity.comps.spring;

            // XXX: crashes if either end has been deleted right now. we may wanna actually make
            // checking if an entity is valid or not a feature if there's not a bette way to handle this?
            var start = entities.getComponent(spring.start, .rb) orelse {
                std.log.err("spring connections require rb, destroying spring entity", .{});
                it.swapRemove();
                continue;
            };

            var end = entities.getComponent(spring.end, .rb) orelse {
                std.log.err("spring connections require rb, destroying spring entity", .{});
                it.swapRemove();
                continue;
            };

            var delta = end.pos.minus(start.pos);
            const dir = delta.normalized();

            // XXX: min length 0 right now, could make min and max (before force) settable though?
            // const x = delta.length() - spring.length;
            const x = std.math.max(delta.length() - spring.length, 0.0);
            const spring_force = spring.k * x;

            const relative_vel = end.vel.dot(dir) - start.vel.dot(dir);
            const start_b = @sqrt(spring.damping * 4.0 * start.mass() * spring.k);
            const start_damping_force = start_b * relative_vel;
            const end_b = @sqrt(spring.damping * 4.0 * end.mass() * spring.k);
            const end_damping_force = end_b * relative_vel;

            const start_impulse = (start_damping_force + spring_force) * delta_s;
            const end_impulse = (end_damping_force + spring_force) * delta_s;
            start.vel.add(dir.scaled(start_impulse / start.mass()));
            end.vel.add(dir.scaled(-end_impulse / start.mass()));
        }
    }

    // Update entities that do damage
    {
        // TODO(mason): hard to keep the components straight, make shorter handles names and get rid of comps
        var damage_it = entities.iterator(.{ .damage, .rb });
        while (damage_it.next()) |damage_entity| {
            const damage = damage_entity.comps.damage;
            const rb = damage_entity.comps.rb;

            {
                var ship_it = entities.iterator(.{ .health, .rb });
                const destroy = while (ship_it.next()) |damageable_entity| {
                    const health = damageable_entity.comps.health;
                    const ship_rb = damageable_entity.comps.rb;
                    if (ship_rb.pos.distanceSqrd(rb.pos) <
                        ship_rb.radius * ship_rb.radius + rb.radius * rb.radius)
                    {
                        if (health.damage(damage.hp) > 0.0) {
                            // spawn shrapnel here
                            const shrapnel_animation = game.shrapnel_animations[
                                std.crypto.random.uintLessThanBiased(usize, game.shrapnel_animations.len)
                            ];
                            const random_vector = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                                .scaled(rb.vel.length() * 0.2);
                            _ = entities.create(.{
                                .lifetime = .{
                                    .seconds = 1.5 + std.crypto.random.float(f32) * 1.0,
                                },
                                .rb = .{
                                    .pos = ship_rb.pos,
                                    .vel = ship_rb.vel.plus(rb.vel.scaled(0.2)).plus(random_vector),
                                    .angle = 2 * math.pi * std.crypto.random.float(f32),
                                    .rotation_vel = 2 * math.pi * std.crypto.random.float(f32),
                                    .radius = game.animationRadius(shrapnel_animation),
                                    .density = 0.001,
                                },
                                .animation = .{
                                    .index = shrapnel_animation,
                                    .time_passed = 0,
                                    .destroys_entity = true,
                                },
                            });

                            break true;
                        }
                    }
                } else false;

                if (destroy) {
                    damage_it.swapRemove();
                    continue;
                }
            }

            rb.angle = rb.vel.angle() + math.pi / 2.0;
        }
    }

    // TODO(mason): take velocity from before impact? i may have messed that up somehow
    // Explode things that reach 0 hp
    {
        var it = entities.iterator(.{.health});
        while (it.next()) |entity| {
            const health = entity.comps.health;

            if (health.hp <= 0) {
                // spawn explosion here
                if (entities.getComponent(entity.handle, .rb)) |rb| {
                    _ = entities.create(.{
                        .lifetime = .{
                            .seconds = 100,
                        },
                        .rb = .{
                            .pos = rb.pos,
                            .vel = rb.vel,
                            .angle = 0,
                            .rotation_vel = 0,
                            .radius = 32,
                            .density = 0.001,
                        },
                        .animation = .{
                            .index = game.explosion_animation,
                            .time_passed = 0,
                            .destroys_entity = true,
                        },
                    });
                }

                // If this is a player controlled ship, spawn a new ship for the player using this
                // ship's input before we destroy it!
                if (entities.getComponent(entity.handle, .ship)) |ship| {
                    if (entities.getComponent(entity.handle, .input)) |input| {
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

                            // Create a new ship from this ship's input, and then destroy it!
                            _ = game.createShip(entities, ship.player, new_pos, facing_angle, input.*);
                        }
                    }
                }

                // Destroy the entity
                it.swapRemove();
                continue;
            }

            // Regen health
            var max_regen = health.regen_ratio * health.max_hp;
            var regen_speed = max_regen / health.regen_s;
            if (health.regen_cooldown_s <= 0.0 and health.hp < max_regen) {
                health.hp = std.math.min(health.hp + regen_speed * delta_s, max_regen);
            }
            health.regen_cooldown_s = std.math.max(health.regen_cooldown_s - delta_s, 0.0);

            // Update invulnerability
            health.invulnerable_s = std.math.max(health.invulnerable_s - delta_s, 0.0);
        }
    }

    // Update ships
    {
        var it = entities.iterator(.{ .ship, .rb, .input });
        while (it.next()) |entity| {
            const ship = entity.comps.ship;
            const rb = entity.comps.rb;
            const input = entity.comps.input;

            if (ship.omnithrusters) {
                rb.vel.add(.{
                    .x = input.getAxis(.thrust_x) * ship.thrust * delta_s,
                    .y = input.getAxis(.thrust_y) * ship.thrust * delta_s,
                });
            } else {
                // convert to 1.0 or 0.0
                rb.angle = @mod(
                    rb.angle + input.getAxis(.turn) * ship.turn_speed * delta_s,
                    2 * math.pi,
                );

                const thrust_input = @intToFloat(f32, @boolToInt(input.isAction(.thrust_forward, .positive, .active)));
                const thrust = V.unit(rb.angle);
                rb.vel.add(thrust.scaled(thrust_input * ship.thrust * delta_s));
            }
        }
    }

    // Update turrets
    {
        var it = entities.iterator(.{ .turrets, .input, .rb });
        while (it.next()) |entity| {
            for (entity.comps.turrets) |*turret| {
                const input = entity.comps.input;
                const rb = entity.comps.rb;
                turret.cooldown_s -= delta_s;
                if (input.isAction(.fire, .positive, .active) and turret.cooldown_s <= 0) {
                    turret.cooldown_s = turret.max_cooldown_s;
                    // TODO(mason): just make separate component for wall
                    var angle = rb.angle;
                    var vel = V.unit(angle).scaled(turret.projectile_speed).plus(rb.vel);
                    var sprite = game.bullet_small;
                    if (turret.aim_opposite_movement) {
                        angle = rb.vel.angle() + std.math.pi;
                        vel = V.zero;
                        sprite = game.bullet_shiny;
                    }
                    _ = entities.create(.{
                        .damage = .{
                            .hp = turret.projectile_damage,
                        },
                        .rb = .{
                            .pos = rb.pos.plus(V.unit(angle + turret.angle).scaled(turret.radius + turret.projectile_radius)),
                            .vel = vel,
                            .angle = 0,
                            .rotation_vel = 0,
                            .radius = turret.projectile_radius,
                            // TODO(mason): modify math to accept 0 and inf mass
                            .density = 0.001,
                        },
                        .sprite = sprite,
                        .collider = .{
                            // Lasers gain energy when bouncing off of rocks
                            .collision_damping = 1,
                            .layer = .projectile,
                        },
                        .lifetime = .{
                            .seconds = turret.projectile_lifetime,
                        },
                    });
                }
            }
        }
    }

    // XXX: break out cooldown logic or no?
    // Update grapple guns
    {
        var it = entities.iterator(.{ .grapple_gun, .input, .rb });
        while (it.next()) |entity| {
            var gg = entity.comps.grapple_gun;
            var input = entity.comps.input;
            var rb = entity.comps.rb;
            gg.cooldown_s -= delta_s;
            if (input.isAction(.fire, .positive, .activated) and gg.cooldown_s <= 0) {
                gg.cooldown_s = gg.max_cooldown_s;

                // XXX: increase cooldown_s?
                if (gg.live) |live| {
                    for (live.joints) |piece| {
                        entities.swapRemove(piece);
                    }
                    for (live.springs) |piece| {
                        entities.swapRemove(piece);
                    }
                    entities.swapRemove(live.hook);
                    gg.live = null;
                } else {
                    // XXX: behave sensibly if the ship that fired it dies...right now crashes cause
                    // one side of the spring has a bad generation
                    // XXX: change sprite!
                    // XXX: make lower mass or something lol
                    // XXX: how do i make it connect? we could replace the hook with the thing it's connected
                    // to when it hits, but, then it'd always connect to the center. so really we wanna
                    // create a new spring that's very strong between the hook and the thing it's connected to.
                    // this means we need to either add a new spring later, or allow for disconnected springs.
                    // if we had addcomponent we could have a hook that dynamically creates a spring on contact,
                    // that's what we actually want!
                    // for now though lets just make the spring ends optional and make a note that this is a good
                    // place for addcomponent.
                    // XXX: then again, addcomponent is easy to add. we just create a new entity move over the components
                    // then delete the old one, and remap the handle.
                    gg.live = .{
                        .joints = undefined,
                        .springs = undefined,
                        .hook = undefined,
                    };

                    // XXX: we COULD add colliders to joints and if it was dense enough you could wrap the rope around things...
                    var dir = V.unit(rb.angle + gg.angle);
                    var vel = rb.vel;
                    const segment_len = 50.0;
                    var pos = rb.pos.plus(dir.scaled(segment_len));
                    for (0..gg.live.?.joints.len) |i| {
                        gg.live.?.joints[i] = entities.create(.{
                            .rb = .{
                                .pos = pos,
                                .vel = vel,
                                .radius = 2,
                                .density = 0.001,
                            },
                            // XXX: ...
                            // .sprite = game.bullet_small,
                        });
                        pos.add(dir.scaled(segment_len));
                    }
                    // XXX: i think the damping code is broken, if i set this to be critically damped
                    // it explodes--even over damping shouldn't do that it should slow things down
                    // extra!
                    // XXX: ah yeah, damping prevents len from going to low for some reason??
                    const hook = Hook{
                        .damping = 0.0,
                        .k = 100.0,
                    };
                    gg.live.?.hook = entities.create(.{
                        .rb = .{
                            .pos = pos,
                            .vel = vel,
                            .angle = 0,
                            .rotation_vel = 0,
                            .radius = 2,
                            .density = 0.001,
                        },
                        .collider = .{
                            .collision_damping = 0,
                            .layer = .hook,
                        },
                        .hook = hook,
                        // XXX: ...
                        // .sprite = game.bullet_small,
                    });
                    for (0..(gg.live.?.springs.len)) |i| {
                        gg.live.?.springs[i] = entities.create(.{
                            .spring = .{
                                .start = if (i == 0)
                                    entity.handle
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
        var it = entities.iterator(.{.animation});
        while (it.next()) |entity| {
            const animation = entity.comps.animation;
            if (animation.destroys_entity and entity.comps.animation.index == .none) {
                it.swapRemove();
                continue;
            }
        }
    }

    // Update lifetimes
    {
        var it = entities.iterator(.{.lifetime});
        while (it.next()) |entity| {
            const lifetime = entity.comps.lifetime;
            lifetime.seconds -= delta_s;
            if (lifetime.seconds <= 0) {
                it.swapRemove();
                continue;
            }
        }
    }
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
        var it = entities.iterator(.{ .rb, .animation });
        while (it.next()) |entity| {
            const rb = entity.comps.rb;
            const animation = entity.comps.animation;
            const frame = assets.animate(animation, delta_s);
            const unscaled_sprite_size = frame.sprite.size();
            const sprite_radius = (unscaled_sprite_size.x + unscaled_sprite_size.y) / 4.0;
            const size_coefficient = rb.radius / sprite_radius;
            const sprite_size = unscaled_sprite_size.scaled(size_coefficient);
            var dest_rect = sdlRect(rb.pos.minus(sprite_size.scaled(0.5)), sprite_size);

            var hidden = false;
            if (entities.getComponent(entity.handle, .health)) |health| {
                if (health.invulnerable_s > 0.0) {
                    var flashes_ps: f32 = 2;
                    if (health.invulnerable_s < 0.25 * std.math.round(Health.max_invulnerable_s * flashes_ps) / flashes_ps) {
                        flashes_ps = 4;
                    }
                    hidden = std.math.sin(flashes_ps * std.math.tau * health.invulnerable_s) > 0.0;
                }
            }

            // We should probably make the sprites half opacity instead of turning them off when
            // flashing for a less jarring effect, but that is difficult right now.
            if (!hidden) {
                sdlAssertZero(c.SDL_RenderCopyEx(
                    renderer,
                    frame.sprite.texture,
                    null, // source rectangle
                    &dest_rect,
                    toDegrees(rb.angle + frame.angle),
                    null, // center of angle
                    c.SDL_FLIP_NONE,
                ));

                if (entities.getComponent(entity.handle, .ship)) |ship| {
                    const sprite = assets.sprite(game.team_sprites[game.players[ship.player].team]);
                    dest_rect.x -= @divTrunc(dest_rect.w, 2);
                    dest_rect.y -= @divTrunc(dest_rect.h, 2);
                    dest_rect.w *= 2;
                    dest_rect.h *= 2;
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
        var it = entities.iterator(.{ .health, .rb });
        while (it.next()) |entity| {
            const health = entity.comps.health;
            const rb = entity.comps.rb;

            // HP bar
            if (health.hp < health.max_hp) {
                const health_bar_size: V = .{ .x = 32, .y = 4 };
                var start = rb.pos.minus(health_bar_size.scaled(0.5)).floored();
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
        }
    }

    // Draw sprites
    // TODO(mason): sort draw calls somehow (can the sdl renderer do depth buffers?)
    {
        var it = entities.iterator(.{ .sprite, .rb });
        while (it.next()) |entity| {
            const rb = entity.comps.rb;
            const sprite = assets.sprite(entity.comps.sprite.*);
            const unscaled_sprite_size = sprite.size();
            const sprite_radius = (unscaled_sprite_size.x + unscaled_sprite_size.y) / 4.0;
            const size_coefficient = rb.radius / sprite_radius;
            const sprite_size = unscaled_sprite_size.scaled(size_coefficient);
            const dest_rect = sdlRect(rb.pos.minus(sprite_size.scaled(0.5)), sprite_size);
            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer,
                sprite.texture,
                null, // source rectangle
                &dest_rect,
                toDegrees(rb.angle),
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
        var it = entities.iterator(.{.spring});
        while (it.next()) |entity| {
            var spring = entity.comps.spring;
            var start = (entities.getComponent(spring.start, .rb) orelse continue).pos;
            var end = (entities.getComponent(spring.end, .rb) orelse continue).pos;
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
    fn ActionMap(comptime Action: type) type {
        return struct {
            turn: Action,
            thrust_forward: Action,
            thrust_x: Action,
            thrust_y: Action,
            fire: Action,

            fn init(default: Action) @This() {
                var map: @This() = undefined;
                inline for (@typeInfo(@This()).Struct.fields) |field| {
                    @field(map, field.name) = default;
                }
                return map;
            }
        };
    }

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

    controller: ?*c.SDL_GameController,
    controller_map: ControllerMap,
    keyboard_map: KeyboardMap,
    state: ActionMap(ActionState) = ActionMap(ActionState).init(.{}),

    pub fn update(self: *@This()) void {
        inline for (@typeInfo(@TypeOf(self.state)).Struct.fields) |field| {
            inline for (.{ Direction.positive, Direction.negative }) |direction| {
                // Check if the keyboard or controller control is activated
                const keyboard_action = @field(self.keyboard_map, field.name);
                const key = if (@field(keyboard_action, @tagName(direction))) |key|
                    c.SDL_GetKeyboardState(null)[key] == 1
                else
                    false;

                const controller_action = @field(self.controller_map, field.name);
                const button = if (@field(controller_action.buttons, @tagName(direction))) |button|
                    c.SDL_GameControllerGetButton(self.controller, button) != 0
                else
                    false;

                const axis = if (controller_action.axis) |axis| a: {
                    const v = c.SDL_GameControllerGetAxis(self.controller, axis);
                    switch (direction) {
                        .positive => break :a v > controller_action.dead_zone,
                        .negative => break :a v < -controller_action.dead_zone,
                    }
                } else false;

                // Update the current state
                const current_state = &@field(@field(self.state, field.name), @tagName(direction));

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
        comptime action: FieldEnum(ControllerMap),
        direction: Direction,
        state: DirectionState,
    ) bool {
        const action_name = comptime std.meta.fieldNames(@TypeOf(self.state))[@enumToInt(action)];
        const current_state = switch (direction) {
            .positive => @field(self.state, action_name).positive,
            .negative => @field(self.state, action_name).negative,
        };
        return switch (state) {
            .active => current_state == .active or current_state == .activated,
            .activated => current_state == .activated,
            .inactive => current_state == .inactive or current_state == .deactivated,
            .deactivated => current_state == .deactivated,
        };
    }

    pub fn getAxis(self: *const @This(), comptime action: FieldEnum(ControllerMap)) f32 {
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
        time_passed: f32,
        destroys_entity: bool = false,
    };
};

const Turret = struct {
    /// Together with angle, this is the location of the turret from the center
    /// of the containing object. Pixels.
    radius: f32,
    /// Together with radius, this is the location of the turret from the
    /// center of the containing object. Radians.
    angle: f32,
    /// Seconds until ready. Less than or equal to 0 means ready.
    cooldown_s: f32,
    /// Seconds until ready. Cooldown is set to this after firing.
    max_cooldown_s: f32,

    aim_opposite_movement: bool = false,

    /// pixels per second
    projectile_speed: f32,
    /// seconds
    projectile_lifetime: f32,
    /// Amount of HP the projectile removes upon landing a hit.
    projectile_damage: f32,
    /// Radius of spawned projectiles.
    projectile_radius: f32,

    enabled: bool = true,

    pub const none: Turret = .{
        .radius = undefined,
        .angle = undefined,
        .cooldown_s = undefined,
        .max_cooldown_s = undefined,
        .projectile_speed = undefined,
        .projectile_lifetime = undefined,
        .projectile_damage = undefined,
        .projectile_radius = undefined,
        .enabled = false,
    };
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
    // XXX: ...
    // /// seconds
    // projectile_lifetime: f32,

    // XXX: if we add this back, need to make it not destroy itself on damage
    // /// Amount of HP the projectile removes upon landing a hit.
    // projectile_damage: f32,

    /// The live chain of projectiles.
    live: ?struct {
        springs: [segments]EntityHandle,
        joints: [segments - 1]EntityHandle,
        hook: EntityHandle,
    } = null,
};

// See https://www.anthropicstudios.com/2020/03/30/symmetric-matrices/
// TODO(mason): packed?
fn SymmetricMatrix(comptime Enum: type, comptime Value: type) type {
    // The length is equal to the upper right half of the matrix, ounding up. We calculate it by
    // dividing the full size of the matrix by two, and then adding back the half of the diagonal
    // that we lost to integer rounding.
    const fields = @typeInfo(Enum).Enum.fields.len;
    const len = (fields * fields + fields) / 2;

    return struct {
        values: [len]Value,

        pub fn init(default: Value) @This() {
            return .{
                .values = [_]Value{default} ** len,
            };
        }

        fn index(a: Enum, b: Enum) usize {
            // Get the low and high indices
            const a_int: usize = @enumToInt(a);
            const b_int: usize = @enumToInt(b);

            const low = std.math.min(a_int, b_int);
            const high = std.math.max(a_int, b_int);

            // Calculate the index (triangle number + offset into the row)
            const tri = high * (high + 1) / 2;
            const col = low;

            // Calculate the resulting index and return it
            return tri + col;
        }

        pub fn get(self: *const @This(), a: Enum, b: Enum) Value {
            return self.values[index(a, b)];
        }

        pub fn set(self: *@This(), a: Enum, b: Enum, value: Value) void {
            self.values[index(a, b)] = value;
        }
    };
}

test "symmetric matrix" {
    // Set up a matrix and fill it with ordered indices
    const Four = enum { zero, one, two, three };
    var matrix = SymmetricMatrix(Four, u8).init(0);
    try std.testing.expectEqual(10, matrix.values.len);

    const inputs = .{
        .{ .zero, .zero },
        .{ .one, .zero },
        .{ .one, .one },
        .{ .two, .zero },
        .{ .two, .one },
        .{ .two, .two },
        .{ .three, .zero },
        .{ .three, .one },
        .{ .three, .two },
        .{ .three, .three },
    };
    inline for (inputs, 0..) |input, i| {
        matrix.set(input[0], input[1], i);
    }
    inline for (inputs, 0..) |input, i| {
        try std.testing.expect(matrix.get(input[0], input[1]) == i);
        try std.testing.expect(matrix.get(input[1], input[0]) == i);
    }
    inline for (inputs, 0..) |input, i| {
        matrix.set(input[1], input[0], i);
    }
    inline for (inputs, 0..) |input, i| {
        try std.testing.expect(matrix.get(input[0], input[1]) == i);
        try std.testing.expect(matrix.get(input[1], input[0]) == i);
    }
}

const RigidBody = struct {
    fn mass(self: RigidBody) f32 {
        return self.density * math.pi * self.radius * self.radius;
    }

    /// pixels
    pos: V,
    /// pixels per second
    vel: V = .{ .x = 0, .y = 0 },
    /// radians
    angle: f32 = 0.0,
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
        // XXX: why doesn't this cause an issue if not set?
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
    still: Animation.Index,
    accel: Animation.Index,

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

const Game = struct {
    assets: *Assets,

    players_buffer: [4]Player,
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
        entities: *Entities,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) EntityHandle {
        return entities.create(.{
            .ship = .{
                .class = .ranger,
                .still = self.ranger_animations.still,
                .accel = self.ranger_animations.accel,
                .turn_speed = math.pi * 1.0,
                .thrust = 160,
                .player = player_index,
            },
            .health = .{
                .hp = 80,
                .max_hp = 80,
            },
            .rb = .{
                .pos = pos,
                .vel = .{ .x = 0, .y = 0 },
                .angle = angle,
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
                .time_passed = 0,
            },
            .turrets = .{
                .{
                    .radius = self.ranger_radius,
                    .angle = 0,
                    .cooldown_s = 0,
                    .max_cooldown_s = 0.10,
                    .projectile_speed = 550,
                    .projectile_lifetime = 1.0,
                    .projectile_damage = 6,
                    .projectile_radius = 8,
                },
                Turret.none,
            },
            .input = input,
        });
    }

    fn createTriangle(
        self: *const @This(),
        entities: *Entities,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) EntityHandle {
        const radius = 24;
        return entities.create(.{
            .ship = .{
                .class = .triangle,
                .still = self.triangle_animations.still,
                .accel = self.triangle_animations.accel,
                .turn_speed = math.pi * 0.9,
                .thrust = 250,
                .player = player_index,
            },
            .health = .{
                .hp = 100,
                .max_hp = 100,
                .regen_ratio = 0.5,
            },
            .rb = .{
                .pos = pos,
                .vel = .{ .x = 0, .y = 0 },
                .angle = angle,
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
                .time_passed = 0,
            },
            .turrets = .{
                .{
                    .radius = radius,
                    .angle = 0,
                    .cooldown_s = 0,
                    .max_cooldown_s = 0.2,
                    .projectile_speed = 700,
                    .projectile_lifetime = 1.0,
                    .projectile_damage = 12,
                    .projectile_radius = 12,
                },
                Turret.none,
            },
            .input = input,
        });
    }

    fn createMilitia(
        self: *const @This(),
        entities: *Entities,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) EntityHandle {
        return entities.create(.{
            .ship = .{
                .class = .militia,
                .still = self.militia_animations.still,
                .accel = self.militia_animations.accel,
                .turn_speed = math.pi * 1.4,
                .thrust = 400,
                .player = player_index,
            },
            .health = .{
                .hp = 80,
                .max_hp = 80,
            },
            .rb = .{
                .pos = pos,
                .vel = .{ .x = 0, .y = 0 },
                .angle = angle,
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
                .time_passed = 0,
            },
            // .grapple_gun = .{
            //     .radius = self.ranger_radius * 10.0,
            //     .angle = 0,
            //     .cooldown_s = 0,
            //     .max_cooldown_s = 0.2,
            //     // XXX: when nonzero, causes the ship to move. wouldn't happen if there was equal
            //     // kickback!
            //     .projectile_speed = 0,
            // },
            .input = input,
            .front_shield = .{},
        });
    }

    fn createKevin(
        self: *const @This(),
        entities: *Entities,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) EntityHandle {
        return entities.create(.{
            .ship = .{
                .class = .kevin,
                .still = self.kevin_animations.still,
                .accel = self.kevin_animations.accel,
                .turn_speed = math.pi * 1.1,
                .thrust = 300,
                .player = player_index,
            },
            .health = .{
                .hp = 300,
                .max_hp = 300,
            },
            .rb = .{
                .pos = pos,
                .vel = .{ .x = 0, .y = 0 },
                .angle = angle,
                .radius = 32,
                .rotation_vel = 0.0,
                .density = 0.02,
            },
            .collider = .{
                .collision_damping = 0.4,
                .layer = .vehicle,
            },
            .animation = .{
                .index = self.kevin_animations.still,
                .time_passed = 0,
            },
            .turrets = .{
                .{
                    .radius = 32,
                    .angle = math.pi * 0.1,
                    .cooldown_s = 0,
                    .max_cooldown_s = 0.2,
                    .projectile_speed = 500,
                    .projectile_lifetime = 1.0,
                    .projectile_damage = 18,
                    .projectile_radius = 18,
                },
                .{
                    .radius = 32,
                    .angle = math.pi * -0.1,
                    .cooldown_s = 0,
                    .max_cooldown_s = 0.2,
                    .projectile_speed = 500,
                    .projectile_lifetime = 1.0,
                    .projectile_damage = 18,
                    .projectile_radius = 18,
                },
            },
            .input = input,
        });
    }

    fn createWendy(
        self: *const @This(),
        entities: *Entities,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) EntityHandle {
        return entities.create(.{
            .ship = .{
                .class = .wendy,
                .still = self.wendy_animations.still,
                .accel = self.wendy_animations.accel,
                .turn_speed = math.pi * 1.0,
                .thrust = 200,
                .player = player_index,
                .omnithrusters = true,
            },
            .health = .{
                .hp = 400,
                .max_hp = 400,
            },
            .rb = .{
                .pos = pos,
                .vel = .{ .x = 0, .y = 0 },
                .angle = angle,
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
                .time_passed = 0,
            },
            .turrets = .{
                .{
                    .radius = self.wendy_radius,
                    .angle = 0,
                    .cooldown_s = 0,
                    .max_cooldown_s = 0.1,
                    .projectile_speed = 0,
                    .projectile_lifetime = 5.0,
                    .projectile_damage = 50,
                    .projectile_radius = 8,
                    .aim_opposite_movement = true,
                },
                Turret.none,
            },
            .input = input,
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
            ranger_sprites[0],
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
            militia_sprites[0],
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
            triangle_sprites[0],
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
            kevin_sprites[0],
            kevin_sprites[1],
        }, kevin_steady_thrust, 10, math.pi / 2.0);

        const wendy_sprites = [_]Sprite.Index{
            try assets.loadSprite("img/ship/wendy0.png"),
            try assets.loadSprite("img/ship/wendy1.png"),
            try assets.loadSprite("img/ship/wendy2.png"),
            try assets.loadSprite("img/ship/wendy3.png"),
        };
        const wendy_still = try assets.addAnimation(&.{
            wendy_sprites[0],
        }, null, 30, math.pi / 2.0);
        const wendy_steady_thrust = try assets.addAnimation(&.{
            wendy_sprites[2],
            wendy_sprites[3],
        }, null, 10, math.pi / 2.0);
        const wendy_accel = try assets.addAnimation(&.{
            wendy_sprites[0],
            wendy_sprites[1],
        }, wendy_steady_thrust, 10, math.pi / 2.0);

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
                .accel = wendy_accel,
            },
            .wendy_radius = wendy_radius,

            .stars = undefined,

            .team_sprites = team_sprites,
        };
    }

    fn createShip(
        game: *Game,
        entities: *Entities,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
    ) EntityHandle {
        const player = game.players[player_index];
        const team = &game.teams[player.team];
        const progression_index = team.ship_progression_index;
        team.ship_progression_index += 1;
        return switch (team.ship_progression[progression_index]) {
            .ranger => game.createRanger(entities, player_index, pos, angle, input),
            .militia => game.createMilitia(entities, player_index, pos, angle, input),
            .triangle => game.createTriangle(entities, player_index, pos, angle, input),
            .kevin => game.createKevin(entities, player_index, pos, angle, input),
            .wendy => game.createWendy(entities, player_index, pos, angle, input),
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

    fn setupScenario(game: *Game, entities: *Entities, scenario: Scenario) void {
        entities.deleteAll(.ship);
        entities.deleteAll(.rb);
        entities.deleteAll(.damage);
        entities.deleteAll(.input);
        entities.deleteAll(.lifetime);
        entities.deleteAll(.sprite);
        entities.deleteAll(.animation);
        entities.deleteAll(.collider);
        entities.deleteAll(.turrets);
        entities.deleteAll(.grapple_gun);
        entities.deleteAll(.health);
        entities.deleteAll(.spring);
        entities.deleteAll(.hook);

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
            var controllers = [4]?*c.SDL_GameController{ null, null, null, null };
            {
                var player_index: u32 = 0;
                for (0..@intCast(usize, c.SDL_NumJoysticks())) |i_usize| {
                    const i = @intCast(u31, i_usize);
                    if (c.SDL_IsGameController(i) != c.SDL_FALSE) {
                        const sdl_controller = c.SDL_GameControllerOpen(i) orelse {
                            panic("SDL_GameControllerOpen failed: {s}\n", .{c.SDL_GetError()});
                        };
                        if (c.SDL_GameControllerGetAttached(sdl_controller) != c.SDL_FALSE) {
                            controllers[i] = sdl_controller;
                            player_index += 1;
                            if (player_index >= controllers.len) break;
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
                    .positive = c.SDL_SCANCODE_DOWN,
                    .negative = c.SDL_SCANCODE_UP,
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
                    .controller = controllers[0],
                    .controller_map = controller_default,
                    .keyboard_map = keyboard_wasd,
                },
                .{
                    .controller = controllers[1],
                    .controller_map = controller_default,
                    .keyboard_map = keyboard_arrows,
                },
                .{
                    .controller = controllers[2],
                    .controller_map = controller_default,
                    .keyboard_map = keyboard_none,
                },
                .{
                    .controller = controllers[3],
                    .controller_map = controller_default,
                    .keyboard_map = keyboard_none,
                },
            };

            for (game.players, input_devices[0..game.players.len], 0..) |_, input, i| {
                const angle = math.pi / 2.0 * @intToFloat(f32, i);
                const pos = display_center.plus(V.unit(angle).scaled(50));
                const player_index = @intCast(u2, i);
                _ = game.createShip(entities, player_index, pos, angle, input);
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

            _ = entities.create(.{
                .sprite = sprite,
                .rb = .{
                    .pos = pos,
                    .vel = V.unit(std.crypto.random.float(f32) * math.pi * 2).scaled(speed),
                    .angle = 0,
                    .rotation_vel = lerp(-1.0, 1.0, std.crypto.random.float(f32)),
                    .radius = radius,
                    .density = 0.10,
                },
                .collider = .{
                    .collision_damping = 1,
                    .layer = .hazard,
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
                .rb = .{
                    .pos = pos,
                    .vel = random_vel,
                    .angle = 2 * math.pi * std.crypto.random.float(f32),
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
}
