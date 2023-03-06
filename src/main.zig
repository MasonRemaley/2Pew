const std = @import("std");
const c = @import("c.zig");
const panic = std.debug.panic;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const math = std.math;
const V = @import("Vec2d.zig");

const display_width = 1920;
const display_height = 1080;
const display_center: V = .{
    .x = display_width / 2.0,
    .y = display_height / 2.0,
};
const display_radius = display_height / 2.0;

const ecs = @import("ecs.zig");
// TODO(mason): some of these have shared behaviors we can factor out e.g. sprites, newtonian mechanics
const Entities = ecs.Entities(.{
    .projectile = Projectile,
    .ship = Ship,
    .rb = RigidBody,
    .input = Input,
    .particle = Particle,
    .sprite = Sprite.Index,
    .collider = Collider,
});
const EntityHandle = ecs.EntityHandle;

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

    const renderer_flags: u32 = c.SDL_RENDERER_PRESENTVSYNC;
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
        var controllers = [2]?*c.SDL_GameController{ null, null };
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
                .controller_axis = c.SDL_CONTROLLER_AXIS_LEFTX,
            },
            .forward = .{
                .controller_button_positive = c.SDL_CONTROLLER_BUTTON_B,
            },
            .fire = .{
                .controller_button_positive = c.SDL_CONTROLLER_BUTTON_A,
            },
        };
        const keyboard_wasd = Input.KeyboardMap{
            .turn = .{
                .key_positive = c.SDL_SCANCODE_D,
                .key_negative = c.SDL_SCANCODE_A,
            },
            .forward = .{
                .key_positive = c.SDL_SCANCODE_W,
            },
            .fire = .{
                .key_positive = c.SDL_SCANCODE_S,
            },
        };
        const keyboard_arrows = Input.KeyboardMap{
            .turn = .{
                .key_positive = c.SDL_SCANCODE_RIGHT,
                .key_negative = c.SDL_SCANCODE_LEFT,
            },
            .forward = .{
                .key_positive = c.SDL_SCANCODE_UP,
            },
            .fire = .{
                .key_positive = c.SDL_SCANCODE_DOWN,
            },
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
        };

        for (input_devices, 0..) |input, i| {
            var ship_template = game.initShip(@intCast(u2, i));
            ship_template.rb.pos = .{
                .x = 500 + 500 * @intToFloat(f32, i),
                .y = 500,
            };
            _ = entities.create(.{
                .ship = ship_template.ship,
                .rb = ship_template.rb,
                .input = input,
                .collider = ship_template.collider,
            });
        }
    }

    // Create rock
    {
        const speed = 100 + std.crypto.random.float(f32) * 400;
        _ = entities.create(.{
            .sprite = game.rock_sprite,
            .rb = .{
                .pos = display_center.plus(.{ .x = 0, .y = 300 }),
                .vel = V.unit(std.crypto.random.float(f32) * math.pi * 2).scaled(speed),
                .angle = 0,
                .radius = @intToFloat(f32, assets.sprite(game.rock_sprite).rect.w) / 2.0,
                .density = 0.10,
                .layer = .hazard,
            },
            .collider = .{
                .collision_damping = 1,
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
        var it = entities.iterator(.{ .input, .ship });
        while (it.next()) |entity| {
            const input = entity.comps.input.*;
            const ship = entity.comps.ship;
            ship.input = .{
                .left = input.isNegative(.turn),
                .right = input.isPositive(.turn),
                .forward = input.isPositive(.forward),
                .fire = input.isPositive(.fire),
            };
        }
    }

    // Update ship animations
    {
        var it = entities.iterator(.{.ship});
        while (it.next()) |entity| {
            const ship = entity.comps.ship;
            if (!ship.prev_input.forward and ship.input.forward) {
                ship.setAnimation(ship.accel);
            } else if (ship.prev_input.forward and !ship.input.forward) {
                ship.setAnimation(ship.still);
            }
            ship.prev_input = ship.input;
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

                if (!RigidBody.collides.get(rb.layer, other.rb.layer)) continue;

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
                const other_mass = rb.mass();
                j /= 1.0 / my_mass + 1.0 / other_mass;
                // apply impulse
                const impulse = normal.scaled(j);
                const ship_impulse = impulse.scaled(1 / my_mass);
                const other_impulse = impulse.scaled(1 / other_mass);
                rb.vel.sub(ship_impulse);
                other.rb.vel.add(other_impulse);

                // Deal HP damage relative to the change in velocity.
                // A very gentle bonk is something like impulse 20, while a
                // very hard bonk is around 300.
                // The basic ranger ship has 80 HP.
                var total_ship_damage: f32 = 0;

                if (entities.getComponent(entity.handle, .ship)) |ship| {
                    const ship_damage = remap(20, 300, 0, 80, ship_impulse.length());
                    ship.hp -= ship_damage;
                    total_ship_damage += ship_damage;
                }
                if (entities.getComponent(other_entity.handle, .ship)) |ship| {
                    const other_damage = remap(20, 300, 0, 80, other_impulse.length());
                    ship.hp -= other_damage;
                    total_ship_damage += other_damage;
                }

                const shrapnel_amt = @floatToInt(
                    u32,
                    @floor(remap_clamped(0, 100, 0, 30, total_ship_damage)),
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
                    _ = entities.create(.{ .particle = .{
                        .anim_playback = .{ .index = shrapnel_animation, .time_passed = 0 },
                        .pos = shrapnel_center.plus(random_offset),
                        .vel = avg_vel.plus(random_vel),
                        .angle = 2 * math.pi * std.crypto.random.float(f32),
                        .rotation_vel = 2 * math.pi * std.crypto.random.float(f32),
                        .duration = 2,
                    } });
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
                if (entities.getComponent(entity.handle, .ship)) |ship| {
                    // punishment for leaving the circle
                    ship.hp -= delta_s * 4;
                }
            }
        }
    }

    // Update projectiles
    {
        // XXX: mason hard to keep the components straight, make shorter handles names and get rid of comps
        var projectile_it = entities.iterator(.{ .projectile, .rb });
        while (projectile_it.next()) |projectile_entity| {
            const projectile = projectile_entity.comps.projectile;
            const rb = projectile_entity.comps.rb;

            projectile.duration -= delta_s;
            if (projectile.duration <= 0) {
                entities.remove(projectile_entity.handle);
                continue;
            }

            {
                var ship_it = entities.iterator(.{ .ship, .rb });
                while (ship_it.next()) |ship_entity| {
                    const ship = ship_entity.comps.ship;
                    const ship_rb = ship_entity.comps.rb;
                    if (ship_rb.pos.distanceSqrd(rb.pos) <
                        ship_rb.radius * ship_rb.radius + rb.radius * rb.radius)
                    {
                        ship.hp -= projectile.damage;

                        // spawn shrapnel here
                        const shrapnel_animation = game.shrapnel_animations[
                            std.crypto.random.uintLessThanBiased(usize, game.shrapnel_animations.len)
                        ];
                        const random_vector = V.unit(std.crypto.random.float(f32) * math.pi * 2)
                            .scaled(rb.vel.length() * 0.2);
                        _ = entities.create(.{ .particle = .{
                            .anim_playback = .{ .index = shrapnel_animation, .time_passed = 0 },
                            .pos = ship_rb.pos,
                            .vel = ship_rb.vel.plus(rb.vel.scaled(0.2)).plus(random_vector),
                            .angle = 2 * math.pi * std.crypto.random.float(f32),
                            .rotation_vel = 2 * math.pi * std.crypto.random.float(f32),
                            .duration = 2,
                        } });

                        entities.remove(projectile_entity.handle);
                        continue;
                    }
                }
            }

            rb.angle = rb.vel.angle() + math.pi / 2.0;
        }
    }

    // Update ships
    {
        var it = entities.iterator(.{ .ship, .rb });
        while (it.next()) |entity| {
            const ship = entity.comps.ship;
            const rb = entity.comps.rb;

            // explode ships that reach 0 hp
            if (ship.hp <= 0) {
                // spawn explosion here
                _ = entities.create(.{ .particle = .{
                    .anim_playback = .{ .index = game.explosion_animation, .time_passed = 0 },
                    .pos = rb.pos,
                    .vel = rb.vel,
                    .angle = 0,
                    .rotation_vel = 0,
                    .duration = 100,
                } });
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
                var ship_template = game.initShip(ship.player);
                ship_template.rb.pos = new_pos;
                ship.* = ship_template.ship;
                rb.* = ship_template.rb;
                continue;
            }

            // TODO(mason): make most recent input take precedence on keyboard?
            const turn_input = // convert to 1.0 or -1.0
                @intToFloat(f32, @boolToInt(ship.input.right)) -
                @intToFloat(f32, @boolToInt(ship.input.left));
            rb.angle = @mod(
                rb.angle + turn_input * ship.turn_speed * delta_s,
                2 * math.pi,
            );

            // convert to 1.0 or 0.0
            const thrust_input = @intToFloat(f32, @boolToInt(ship.input.forward));
            const thrust = V.unit(rb.angle);
            rb.vel.add(thrust.scaled(thrust_input * ship.thrust * delta_s));

            if (ship.turret) |*turret| {
                turret.cooldown -= delta_s;
                if (ship.input.fire and turret.cooldown <= 0) {
                    turret.cooldown = turret.cooldown_amount;
                    _ = entities.create(.{
                        .projectile = .{
                            .duration = turret.projectile_duration,
                            .damage = turret.projectile_damage,
                        },
                        .rb = .{
                            .pos = rb.pos.plus(V.unit(rb.angle + turret.angle).scaled(turret.radius)),
                            .vel = V.unit(rb.angle).scaled(turret.projectile_speed).plus(rb.vel),
                            .angle = 0,
                            .radius = 2,
                            // TODO(mason): modify math to accept 0 and inf mass
                            .density = 0.001,
                            .layer = .projectile,
                        },
                        .sprite = game.bullet_small,
                        .collider = .{
                            .collision_damping = 0,
                        },
                    });
                }
            }
        }
    }

    // Update particles
    {
        var it = entities.iterator(.{.particle});
        while (it.next()) |entity| {
            const particle = entity.comps.particle;
            particle.duration -= delta_s;
            if (particle.anim_playback.index == .none or particle.duration <= 0) {
                entities.remove(entity.handle);
                continue;
            }
            particle.pos.add(particle.vel.scaled(delta_s));
            particle.angle = @mod(
                particle.angle + particle.rotation_vel * delta_s,
                2 * math.pi,
            );
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

    // Draw ships
    {
        var it = entities.iterator(.{ .ship, .rb });
        while (it.next()) |entity| {
            const ship = entity.comps.ship;
            const rb = entity.comps.rb;
            const sprite = assets.animate(&ship.anim_playback, delta_s);
            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer,
                sprite.texture,
                null, // source rectangle
                &sprite.toSdlRect(rb.pos),
                // The ship asset images point up instead of to the right.
                toDegrees(rb.angle + math.pi / 2.0),
                null, // center of angle
                c.SDL_FLIP_NONE,
            ));

            // HP bar
            if (ship.hp < ship.max_hp) {
                const health_bar_size: V = .{ .x = 32, .y = 4 };
                var start = rb.pos.minus(health_bar_size.scaled(0.5)).floored();
                start.y -= rb.radius + health_bar_size.y;
                sdlAssertZero(c.SDL_SetRenderDrawColor(renderer, 0xff, 0xff, 0xff, 0xff));
                sdlAssertZero(c.SDL_RenderFillRect(renderer, &sdlRect(
                    start.minus(.{ .x = 1, .y = 1 }),
                    health_bar_size.plus(.{ .x = 2, .y = 2 }),
                )));
                const hp_percent = ship.hp / ship.max_hp;
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
            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer,
                sprite.texture,
                null, // source rectangle
                &sprite.toSdlRect(rb.pos),
                toDegrees(rb.angle),
                null, // center of rotation
                c.SDL_FLIP_NONE,
            ));
        }
    }

    // Draw particles
    {
        var it = entities.iterator(.{.particle});
        while (it.next()) |entity| {
            const particle = entity.comps.particle;
            const sprite = assets.animate(&particle.anim_playback, delta_s);
            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer,
                sprite.texture,
                null, // source rectangle
                &sprite.toSdlRect(particle.pos),
                toDegrees(particle.angle),
                null, // center of rotation
                c.SDL_FLIP_NONE,
            ));
        }
    }

    c.SDL_RenderPresent(renderer);
}

const Player = struct {
    ship_progression_index: u32,
    ship_progression: []const Ship.Class,
};

pub fn sdlAssertZero(ret: c_int) void {
    if (ret == 0) return;
    panic("sdl function returned an error: {s}", .{c.SDL_GetError()});
}

const Input = struct {
    pub const ControllerAction = struct {
        controller_axis: ?c.SDL_GameControllerAxis = null,
        controller_button_positive: ?c.SDL_GameControllerButton = null,
        controller_button_negative: ?c.SDL_GameControllerButton = null,
        dead_zone: u15 = 10000,
    };

    pub const KeyboardAction = struct {
        key_positive: ?u16 = null,
        key_negative: ?u16 = null,
    };

    pub const KeyboardMap = ActionMap(KeyboardAction);
    pub const ControllerMap = ActionMap(ControllerAction);

    controller: ?*c.SDL_GameController,
    controller_map: ControllerMap,
    keyboard_map: KeyboardMap,

    fn ActionMap(comptime Action: type) type {
        return struct {
            turn: Action,
            forward: Action,
            fire: Action,
        };
    }

    pub fn isPositive(self: *const @This(), comptime action: std.meta.FieldEnum(ControllerMap)) bool {
        const keyboard_action = @field(self.keyboard_map, std.meta.fieldNames(ControllerMap)[@enumToInt(action)]);
        const key = if (keyboard_action.key_positive) |key|
            c.SDL_GetKeyboardState(null)[key] == 1
        else
            false;

        const controller_action = @field(self.controller_map, std.meta.fieldNames(ControllerMap)[@enumToInt(action)]);
        const button = if (controller_action.controller_button_positive) |button|
            c.SDL_GameControllerGetButton(self.controller, button) != 0
        else
            false;
        const axis = if (controller_action.controller_axis) |axis|
            c.SDL_GameControllerGetAxis(self.controller, axis) > controller_action.dead_zone
        else
            false;

        return key or button or axis;
    }

    pub fn isNegative(self: *const @This(), comptime action: std.meta.FieldEnum(ControllerMap)) bool {
        const keyboard_action = @field(self.keyboard_map, std.meta.fieldNames(ControllerMap)[@enumToInt(action)]);
        const key = if (keyboard_action.key_negative) |key|
            c.SDL_GetKeyboardState(null)[key] == 1
        else
            false;

        const controller_action = @field(self.controller_map, std.meta.fieldNames(ControllerMap)[@enumToInt(action)]);
        const button = if (controller_action.controller_button_negative) |button|
            c.SDL_GameControllerGetButton(self.controller, button) != 0
        else
            false;
        const axis = if (controller_action.controller_axis) |axis|
            c.SDL_GameControllerGetAxis(self.controller, axis) < -@as(i16, controller_action.dead_zone)
        else
            false;

        return key or button or axis;
    }
};

const Projectile = struct {
    /// seconds
    duration: f32,
    /// Amount of HP the projectile removes on hit.
    damage: f32,
};

// TODO(mason): we can use rb here but...if we do break out Collider into a separate component so we're not
// running an n^2 algorithm on every particle!
const Particle = struct {
    anim_playback: Animation.Playback,
    /// pixels
    pos: V,
    /// pixels per second
    vel: V,
    /// radians
    angle: f32,
    /// radians per second
    rotation_vel: f32,
    /// seconds
    duration: f32,
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

    /// Index into animations array.
    const Index = enum(u32) {
        none = math.maxInt(u32),
        _,
    };

    const Playback = struct {
        index: Index,
        /// number of seconds passed since Animation start.
        time_passed: f32,
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
    projectile_duration: f32,
    /// Amount of HP the projectile removes upon landing a hit.
    projectile_damage: f32,
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
    const Layer = enum {
        vehicle,
        hazard,
        projectile,
    };

    const collides: SymmetricMatrix(Layer, bool) = collides: {
        var m = SymmetricMatrix(Layer, bool).init(true);
        m.set(.vehicle, .projectile, false);
        break :collides m;
    };

    fn mass(self: RigidBody) f32 {
        return self.density * math.pi * self.radius * self.radius;
    }

    /// pixels
    pos: V,
    /// pixels per second
    vel: V,
    /// radians
    angle: f32,
    radius: f32,
    // TODO(mason): why density and not inverse mass? probably a good reason i just wanna understand
    // gotta look at how it's used.
    density: f32,
    layer: Layer,
};

const Collider = struct {
    collision_damping: f32,
};

const Ship = struct {
    still: Animation.Index,
    accel: Animation.Index,
    anim_playback: Animation.Playback,

    /// radians per second
    turn_speed: f32,
    /// pixels per second squared
    thrust: f32,

    /// Player or AI decisions on what they want the ship to do.
    input: InputState,
    /// Keeps track of the input from last frame so that the game logic can
    /// notice when a button is first pressed.
    prev_input: InputState,

    turret: ?Turret,

    hp: f32,
    max_hp: f32,

    class: Class,
    player: u2,

    const Class = enum { ranger, militia };

    const InputState = packed struct {
        fire: bool = false,
        forward: bool = false,
        left: bool = false,
        right: bool = false,
    };

    fn setAnimation(ship: *Ship, animation: Animation.Index) void {
        ship.anim_playback = .{
            .index = animation,
            .time_passed = 0,
        };
    }
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
};

// TODO(mason): we can just make anon structs as prefabs, and concat them as needed before creation.
// if there's no builtin concat for anon structs i can write one.
const ShipTemplate = struct {
    ship: Ship,
    rb: RigidBody,
    collider: Collider,
};

const Game = struct {
    assets: *Assets,

    players: [2]Player,

    ranger_template: ShipTemplate,
    militia_template: ShipTemplate,

    shrapnel_animations: [shrapnel_sprite_names.len]Animation.Index,
    explosion_animation: Animation.Index,

    ring_bg: Sprite.Index,
    star_small: Sprite.Index,
    star_large: Sprite.Index,
    planet_red: Sprite.Index,
    bullet_small: Sprite.Index,

    rock_sprite: Sprite.Index,

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
            try assets.addAnimation(&.{shrapnel_sprites[0]}, null, 30),
            try assets.addAnimation(&.{shrapnel_sprites[1]}, null, 30),
            try assets.addAnimation(&.{shrapnel_sprites[2]}, null, 30),
        };

        const ranger_sprites = [_]Sprite.Index{
            try assets.loadSprite("img/ship/ranger0.png"),
            try assets.loadSprite("img/ship/ranger1.png"),
            try assets.loadSprite("img/ship/ranger2.png"),
            try assets.loadSprite("img/ship/ranger3.png"),
        };
        const ranger_still = try assets.addAnimation(&.{
            ranger_sprites[0],
        }, null, 30);
        const ranger_steady_thrust = try assets.addAnimation(&.{
            ranger_sprites[2],
            ranger_sprites[3],
        }, null, 10);
        const ranger_accel = try assets.addAnimation(&.{
            ranger_sprites[0],
            ranger_sprites[1],
        }, ranger_steady_thrust, 10);

        const militia_sprites = [_]Sprite.Index{
            try assets.loadSprite("img/ship/militia0.png"),
            try assets.loadSprite("img/ship/militia1.png"),
            try assets.loadSprite("img/ship/militia2.png"),
            try assets.loadSprite("img/ship/militia3.png"),
        };
        const militia_still = try assets.addAnimation(&.{
            militia_sprites[0],
        }, null, 30);
        const militia_steady_thrust = try assets.addAnimation(&.{
            militia_sprites[2],
            militia_sprites[3],
        }, null, 10);
        const militia_accel = try assets.addAnimation(&.{
            militia_sprites[0],
            militia_sprites[1],
        }, militia_steady_thrust, 10);

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
        }, .none, 30);

        const ranger_radius = @intToFloat(f32, assets.sprite(ranger_sprites[0]).rect.w) / 2.0;
        const militia_radius = @intToFloat(f32, assets.sprite(militia_sprites[0]).rect.w) / 2.0;
        const ranger_template: ShipTemplate = .{
            .ship = .{
                .class = .ranger,
                .input = .{},
                .prev_input = .{},
                .still = ranger_still,
                .accel = ranger_accel,
                .anim_playback = .{ .index = ranger_still, .time_passed = 0 },
                .turn_speed = math.pi * 1.1,
                .thrust = 150,
                .turret = .{
                    .radius = ranger_radius,
                    .angle = 0,
                    .cooldown = 0,
                    .cooldown_amount = 0.2,
                    .projectile_speed = 500,
                    .projectile_duration = 0.5,
                    .projectile_damage = 10,
                },
                .hp = 80,
                .max_hp = 80,
                .player = undefined,
            },
            .rb = .{
                .pos = .{ .x = 0, .y = 0 },
                .vel = .{ .x = 0, .y = 0 },
                .angle = -math.pi / 2.0,
                .radius = ranger_radius,
                .density = 0.02,
                .layer = .vehicle,
            },
            .collider = .{
                .collision_damping = 0.4,
            },
        };

        const militia_template: ShipTemplate = .{
            .ship = .{
                .class = .militia,
                .input = .{},
                .prev_input = .{},
                .still = militia_still,
                .accel = militia_accel,
                .anim_playback = .{ .index = militia_still, .time_passed = 0 },
                .turn_speed = math.pi * 1.2,
                .thrust = 300,
                .turret = null,
                .hp = 80,
                .max_hp = 80,
                .player = undefined,
            },
            .rb = .{
                .pos = .{ .x = 0, .y = 0 },
                .vel = .{ .x = 0, .y = 0 },
                .angle = -math.pi / 2.0,
                .radius = militia_radius,
                .density = 0.02,
                .layer = .vehicle,
            },
            .collider = .{
                .collision_damping = 0.4,
            },
        };

        return .{
            .assets = assets,
            .players = .{
                .{
                    .ship_progression_index = 0,
                    .ship_progression = &.{ .ranger, .militia },
                },
                .{
                    .ship_progression_index = 0,
                    .ship_progression = &.{ .ranger, .militia },
                },
            },
            .shrapnel_animations = shrapnel_animations,
            .explosion_animation = explosion_animation,
            .ranger_template = ranger_template,
            .militia_template = militia_template,

            .ring_bg = ring_bg,
            .star_small = star_small,
            .star_large = star_large,
            .planet_red = planet_red,
            .bullet_small = bullet_small,
            .rock_sprite = rock_sprites[0],
        };
    }

    // TODO(mason): make this not weird
    fn initShip(game: *Game, player_index: u2) ShipTemplate {
        const player = game.players[player_index];
        var ship = switch (player.ship_progression[player.ship_progression_index]) {
            .ranger => game.ranger_template,
            .militia => game.militia_template,
        };
        ship.ship.player = player_index;
        return ship;
    }
};

const Assets = struct {
    gpa: Allocator,
    renderer: *c.SDL_Renderer,
    dir: std.fs.Dir,
    sprites: std.ArrayListUnmanaged(Sprite),
    frames: std.ArrayListUnmanaged(Sprite.Index),
    animations: std.ArrayListUnmanaged(Animation),

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

    fn animate(a: Assets, anim: *Animation.Playback, delta_s: f32) Sprite {
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
        return frame_sprite;
    }

    /// null next_animation means to loop.
    fn addAnimation(
        a: *Assets,
        frames: []const Sprite.Index,
        next_animation: ?Animation.Index,
        fps: f32,
    ) !Animation.Index {
        try a.frames.appendSlice(a.gpa, frames);
        const result = @intToEnum(Animation.Index, a.animations.items.len);
        try a.animations.append(a.gpa, .{
            .start = @intCast(u32, a.frames.items.len - frames.len),
            .len = @intCast(u32, frames.len),
            .next = next_animation orelse result,
            .fps = fps,
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
