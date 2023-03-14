const std = @import("std");
const c = @import("c.zig");
const panic = std.debug.panic;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const math = std.math;
const V = @import("Vec2d.zig");
const FieldEnum = std.meta.FieldEnum;

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
    .turret = Turret,
    .grapple_gun = GrappleGun,
    .health = Health,
    .spring = Spring,
    .hook = Hook,
});
const EntityHandle = ecs.EntityHandle;

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
    var entities = try Entities.init(gpa);
    defer entities.deinit(gpa);

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
            .turn = .{
                .axis = c.SDL_CONTROLLER_AXIS_LEFTX,
            },
            .forward = .{
                .buttons = .{ .positive = c.SDL_CONTROLLER_BUTTON_B },
            },
            .fire = .{
                .buttons = .{ .positive = c.SDL_CONTROLLER_BUTTON_A },
            },
        };
        const keyboard_wasd = Input.KeyboardMap{
            .turn = .{
                .positive = c.SDL_SCANCODE_D,
                .negative = c.SDL_SCANCODE_A,
            },
            .forward = .{
                .positive = c.SDL_SCANCODE_W,
            },
            .fire = .{
                .positive = c.SDL_SCANCODE_S,
            },
        };
        const keyboard_arrows = Input.KeyboardMap{
            .turn = .{
                .positive = c.SDL_SCANCODE_RIGHT,
                .negative = c.SDL_SCANCODE_LEFT,
            },
            .forward = .{
                .positive = c.SDL_SCANCODE_UP,
            },
            .fire = .{
                .positive = c.SDL_SCANCODE_DOWN,
            },
        };
        const keyboard_none: Input.KeyboardMap = .{
            .turn = .{},
            .forward = .{},
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

        for (input_devices, 0..) |input, i| {
            const angle = math.pi / 2.0 * @intToFloat(f32, i);
            const pos = display_center.plus(V.unit(angle).scaled(50));
            _ = game.createShip(&entities, @intCast(u2, i), pos, angle, input);
        }
    }

    // Create rock
    for (0..4) |_| {
        // XXX: because of how damage interacts with rbs, sometimes rocks don't get damaged when being shot, we should
        // process damage first or do it as part of collision detection!
        // maybe this is why health bars sometimes seem to not show up?
        const speed = std.crypto.random.float(f32) * 300;
        const radius = 10 + std.crypto.random.float(f32) * 110;
        const sprite = game.rock_sprites[std.crypto.random.uintLessThanBiased(usize, game.rock_sprites.len)];
        _ = entities.create(.{
            .sprite = sprite,
            .rb = .{
                .pos = display_center.plus(.{ .x = 0.0, .y = 300.0 }),
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
    var stars: [150]Star = undefined;
    generateStars(&stars);

    // Run sim
    var delta_s: f32 = 1.0 / 60.0;
    var timer = try std.time.Timer.start();

    while (true) {
        if (poll()) return;
        update(&entities, &game, delta_s);
        render(assets, &entities, stars, game, delta_s);

        // TODO(mason): we also want a min frame time so we don't get supririsng floating point
        // results if it's too close to zero!
        // Adjust our expectd delta time a little every frame. We cap it at `max_frame_time` to
        // prevent e.g. a slow alt tab from messing things up too much.
        const delta_rwa_bias = 0.05;
        const max_frame_time = 1.0 / 30.0;
        var last_delta_s = @intToFloat(f32, timer.lap()) / std.time.ns_per_s;
        delta_s = lerp(delta_s, std.math.min(last_delta_s, max_frame_time), delta_rwa_bias);
        if (profile) std.debug.print("{d}ms\n", .{last_delta_s * 1000.0});
    }
}

fn poll() bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        switch (event.type) {
            c.SDL_QUIT => return true,
            c.SDL_KEYDOWN => switch (event.key.keysym.scancode) {
                c.SDL_SCANCODE_ESCAPE => return true,
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
        }
    }

    // Update ship animations
    {
        var it = entities.iterator(.{ .ship, .animation, .input });
        while (it.next()) |entity| {
            const ship = entity.comps.ship;
            const animation = entity.comps.animation;
            const input = entity.comps.input;
            if (input.isAction(.forward, .positive, .activated)) {
                // TODO(mason): do initialziers that reference the thing they're being set on still
                // need to be on separate lines? (this doesn't do that anymore either way)
                animation.* = .{
                    .index = ship.accel,
                    .time_passed = 0,
                };
            } else if (input.isAction(.forward, .positive, .deactivated)) {
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

                if (entities.getComponent(entity.handle, .health)) |health| {
                    const damage = remap(20, 300, 0, 80, impulse.length());
                    health.hp -= damage;
                    total_damage += damage;
                }
                if (entities.getComponent(other_entity.handle, .health)) |health| {
                    const damage = remap(20, 300, 0, 80, other_impulse.length());
                    health.hp -= damage;
                    total_damage += damage;
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
                            .seconds = 2,
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
                const gravity = 400;
                const gravity_v = display_center.minus(rb.pos).normalized().scaled(gravity * delta_s);
                rb.vel.add(gravity_v);
                if (entities.getComponent(entity.handle, .health)) |health| {
                    // punishment for leaving the circle
                    health.hp -= delta_s * 4;
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
                entities.remove(entity.handle);
                continue;
            };

            var end = entities.getComponent(spring.end, .rb) orelse {
                std.log.err("spring connections require rb, destroying spring entity", .{});
                entities.remove(entity.handle);
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
                while (ship_it.next()) |damageable_entity| {
                    const health = damageable_entity.comps.health;
                    const ship_rb = damageable_entity.comps.rb;
                    if (ship_rb.pos.distanceSqrd(rb.pos) <
                        ship_rb.radius * ship_rb.radius + rb.radius * rb.radius)
                    {
                        health.hp -= damage.hp;

                        // spawn shrapnel here
                        const shrapnel_animation = game.shrapnel_animations[
                            std.crypto.random.uintLessThanBiased(usize, game.shrapnel_animations.len)
                        ];
                        const random_vector = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                            .scaled(rb.vel.length() * 0.2);
                        _ = entities.create(.{
                            .lifetime = .{
                                .seconds = 2,
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

                        entities.remove(damage_entity.handle);
                        break;
                    }
                }
            }

            rb.angle = rb.vel.angle() + math.pi / 2.0;
        }
    }

    // TODO(mason): take velocity from before impact? i may have messed that up somehow
    // Explode things that reach 0 hp
    {
        var it = entities.iterator(.{ .health, .rb });
        while (it.next()) |entity| {
            const health = entity.comps.health;
            const rb = entity.comps.rb;
            if (health.hp <= 0) {
                // spawn explosion here
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

                // If this is a playe controlled ship, spawn a new ship for the player using this
                // ship's input before we destroy it!
                if (entities.getComponent(entity.handle, .ship)) |ship| {
                    if (entities.getComponent(entity.handle, .input)) |input| {
                        // give player their next ship
                        const player = &game.players[ship.player];
                        player.ship_progression_index += 1;
                        if (player.ship_progression_index >= player.ship_progression.len) {
                            // this player would lose the game, but instead let's just
                            // give them another ship
                            player.ship_progression_index = 0;
                        }
                        const new_angle = math.pi * 2 * std.crypto.random.float(f32);
                        const new_pos = display_center.plus(V.unit(new_angle).scaled(500));
                        const facing_angle = new_angle + math.pi;

                        // Create a new ship from this ship's input, and then destroy it!
                        _ = game.createShip(entities, ship.player, new_pos, facing_angle, input.*);
                    }
                }

                // Destroy the entity
                entities.remove(entity.handle);
                continue;
            }
        }
    }

    // Update ships
    {
        var it = entities.iterator(.{ .ship, .rb, .input });
        while (it.next()) |entity| {
            const ship = entity.comps.ship;
            const rb = entity.comps.rb;
            const input = entity.comps.input;

            rb.angle = @mod(
                rb.angle + input.getAxis(.turn) * ship.turn_speed * delta_s,
                2 * math.pi,
            );

            // convert to 1.0 or 0.0
            const thrust_input = @intToFloat(f32, @boolToInt(input.isAction(.forward, .positive, .active)));
            const thrust = V.unit(rb.angle);
            rb.vel.add(thrust.scaled(thrust_input * ship.thrust * delta_s));
        }
    }

    // Update turrets
    {
        var it = entities.iterator(.{ .turret, .input, .rb });
        while (it.next()) |entity| {
            var turret = entity.comps.turret;
            var input = entity.comps.input;
            var rb = entity.comps.rb;
            turret.cooldown -= delta_s;
            if (input.isAction(.fire, .positive, .active) and turret.cooldown <= 0) {
                turret.cooldown = turret.cooldown_amount;
                _ = entities.create(.{
                    .damage = .{
                        .hp = turret.projectile_damage,
                    },
                    .rb = .{
                        .pos = rb.pos.plus(V.unit(rb.angle + turret.angle).scaled(turret.radius)),
                        .vel = V.unit(rb.angle).scaled(turret.projectile_speed).plus(rb.vel),
                        .angle = 0,
                        .rotation_vel = 0,
                        .radius = 12,
                        // TODO(mason): modify math to accept 0 and inf mass
                        .density = 0.001,
                    },
                    .sprite = game.bullet_small,
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

    // XXX: break out cooldown logic or no?
    // Update grapple guns
    {
        var it = entities.iterator(.{ .grapple_gun, .input, .rb });
        while (it.next()) |entity| {
            var gg = entity.comps.grapple_gun;
            var input = entity.comps.input;
            var rb = entity.comps.rb;
            gg.cooldown -= delta_s;
            if (input.isAction(.fire, .positive, .activated) and gg.cooldown <= 0) {
                gg.cooldown = gg.cooldown_amount;

                // XXX: increase cooldown?
                if (gg.live) |live| {
                    for (live.joints) |piece| {
                        entities.remove(piece);
                    }
                    for (live.springs) |piece| {
                        entities.remove(piece);
                    }
                    entities.remove(live.hook);
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
                entities.remove(entity.handle);
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
                entities.remove(entity.handle);
                continue;
            }
        }
    }
}

// TODO(mason): allow passing in const for rendering to make sure no modifications
fn render(assets: Assets, entities: *Entities, stars: anytype, game: Game, delta_s: f32) void {
    const renderer = assets.renderer;

    // Clear screen
    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0x00, 0x00, 0x00, 0xff));
    sdlAssertZero(c.SDL_RenderClear(renderer));

    // Draw stars
    for (stars) |star| {
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
            const dest_rect = sdlRect(rb.pos.minus(sprite_size.scaled(0.5)), sprite_size);

            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer,
                frame.sprite.texture,
                null, // source rectangle
                &dest_rect,
                toDegrees(rb.angle + frame.angle),
                null, // center of angle
                c.SDL_FLIP_NONE,
            ));
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
                if (hp_percent > 0.45) {
                    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0x00, 0x94, 0x13, 0xff));
                } else {
                    sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0xe2, 0x00, 0x03, 0xff));
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

    c.SDL_RenderPresent(renderer);
}

const Player = struct {
    ship_progression_index: u32,
    ship_progression: []const Ship.Class,
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
            forward: Action,
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
    cooldown: f32,
    /// Seconds until ready. Cooldown is set to this after firing.
    cooldown_amount: f32,

    /// pixels per second
    projectile_speed: f32,
    /// seconds
    projectile_lifetime: f32,
    /// Amount of HP the projectile removes upon landing a hit.
    projectile_damage: f32,
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
    cooldown: f32,
    /// Seconds until ready. Cooldown is set to this after firing.
    cooldown_amount: f32,

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
        m.set(.vehicle, .projectile, false);
        // XXX: why doesn't this cause an issue if not set?
        m.set(.projectile, .hook, false);
        break :interacts m;
    };

    collision_damping: f32,
    layer: Layer,
};

const Health = struct {
    hp: f32,
    max_hp: f32,
};

const Ship = struct {
    still: Animation.Index,
    accel: Animation.Index,

    /// radians per second
    turn_speed: f32,
    /// pixels per second squared
    thrust: f32,

    class: Class,
    player: u2,

    const Class = enum { ranger, militia, sketch1, sketch2, sketch3, sketch4 };
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

    players: [4]Player,

    shrapnel_animations: [shrapnel_sprite_names.len]Animation.Index,
    explosion_animation: Animation.Index,

    ring_bg: Sprite.Index,
    star_small: Sprite.Index,
    star_large: Sprite.Index,
    planet_red: Sprite.Index,
    bullet_small: Sprite.Index,

    rock_sprites: [rock_sprite_names.len]Sprite.Index,

    ranger_animations: ShipAnimations,
    ranger_radius: f32,

    militia_animations: ShipAnimations,
    militia_radius: f32,

    sketch_animations: [4]ShipAnimations,

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
                .turn_speed = math.pi * 1.1,
                .thrust = 150,
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
            .turret = .{
                .radius = self.ranger_radius,
                .angle = 0,
                .cooldown = 0,
                .cooldown_amount = 0.2,
                .projectile_speed = 500,
                .projectile_lifetime = 1.0,
                .projectile_damage = 10,
            },
            .input = input,
        });
    }

    fn createSketch(
        self: *const @This(),
        entities: *Entities,
        player_index: u2,
        pos: V,
        angle: f32,
        input: Input,
        class: Ship.Class,
    ) EntityHandle {
        const index: u8 = switch (class) {
            .sketch1 => 0,
            .sketch2 => 1,
            .sketch3 => 2,
            .sketch4 => 3,
            else => unreachable,
        };
        const radius = 24;
        return entities.create(.{
            .ship = .{
                .class = class,
                .still = self.sketch_animations[index].still,
                .accel = self.sketch_animations[index].accel,
                .turn_speed = math.pi * 0.9,
                .thrust = 300,
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
                .radius = radius,
                .rotation_vel = 0.0,
                .density = 0.02,
            },
            .collider = .{
                .collision_damping = 0.4,
                .layer = .vehicle,
            },
            .animation = .{
                .index = self.sketch_animations[index].still,
                .time_passed = 0,
            },
            .turret = .{
                .radius = radius,
                .angle = 0,
                .cooldown = 0,
                .cooldown_amount = 0.2,
                .projectile_speed = 700,
                .projectile_lifetime = 1.0,
                .projectile_damage = 10,
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
                .turn_speed = math.pi * 1.2,
                .thrust = 300,
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
                .density = 0.04,
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
            //     .cooldown = 0,
            //     .cooldown_amount = 0.2,
            //     // XXX: when nonzero, causes the ship to move. wouldn't happen if there was equal
            //     // kickback!
            //     .projectile_speed = 0,
            // },
            .input = input,
        });
    }

    fn init(assets: *Assets) !Game {
        const ring_bg = try assets.loadSprite("img/ring.png");
        const star_small = try assets.loadSprite("img/star/small.png");
        const star_large = try assets.loadSprite("img/star/large.png");
        const planet_red = try assets.loadSprite("img/planet-red.png");
        const bullet_small = try assets.loadSprite("img/bullet/small.png");

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

        const ranger_radius = @intToFloat(f32, assets.sprite(ranger_sprites[0]).rect.w) / 2.0;
        const militia_radius = @intToFloat(f32, assets.sprite(militia_sprites[0]).rect.w) / 2.0;

        var sketch_animations: [4]ShipAnimations = undefined;
        for (&sketch_animations, 1..) |*ani, i| {
            const name = try std.fmt.allocPrint(assets.gpa, "img/ship/test{d}.png", .{i});
            const test_sprite = try assets.loadSprite(name);
            const test_still = try assets.addAnimation(&.{
                test_sprite,
            }, null, 30, math.pi / 2.0);
            const test_steady_thrust = try assets.addAnimation(&.{
                test_sprite,
            }, null, 10, math.pi / 2.0);
            const test_accel = try assets.addAnimation(&.{
                test_sprite,
            }, test_steady_thrust, 10, math.pi / 2.0);
            ani.* = .{
                .still = test_still,
                .accel = test_accel,
            };
        }

        const progression = &.{ .ranger, .militia, .sketch1, .sketch2, .sketch3, .sketch4 };
        const player_init: Player = .{
            .ship_progression_index = 0,
            .ship_progression = progression,
        };

        return .{
            .assets = assets,
            .players = .{ player_init, player_init, player_init, player_init },
            .shrapnel_animations = shrapnel_animations,
            .explosion_animation = explosion_animation,

            .ring_bg = ring_bg,
            .star_small = star_small,
            .star_large = star_large,
            .planet_red = planet_red,
            .bullet_small = bullet_small,
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

            .sketch_animations = sketch_animations,
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
        return switch (player.ship_progression[player.ship_progression_index]) {
            .ranger => game.createRanger(entities, player_index, pos, angle, input),
            .militia => game.createMilitia(entities, player_index, pos, angle, input),

            .sketch1,
            .sketch2,
            .sketch3,
            .sketch4,
            => |class| game.createSketch(entities, player_index, pos, angle, input, class),
        };
    }

    fn animationRadius(game: Game, animation_index: Animation.Index) f32 {
        const assets = game.assets;
        const animation = assets.animations.items[@enumToInt(animation_index)];
        const sprite_index = assets.frames.items[animation.start];
        const sprite = assets.sprites.items[@enumToInt(sprite_index)];
        return sprite.radius();
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
    _ = ecs;
}
