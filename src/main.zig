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
// TODO(mason): some of these have shared behaviors we can factor out e.g. sprites, newtonian mechanics
// TODO(mason): add debug text for frame rate, number of live entities, etc
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
});
const Prefab = Entities.Prefab;
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
            const pos = .{
                .x = 500 + 500 * @intToFloat(f32, i),
                .y = 500,
            };
            _ = game.createShip(&entities, @intCast(u2, i), pos, input);
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
                .rotation_vel = lerp(-1.0, 1.0, std.crypto.random.float(f32)),
                .radius = @intToFloat(f32, assets.sprite(game.rock_sprite).rect.w) / 2.0,
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
                    _ = entities.create(.{
                        .lifetime = .{
                            .seconds = 2,
                        },
                        .rb = .{
                            .pos = shrapnel_center.plus(random_offset),
                            .vel = avg_vel.plus(random_vel),
                            .angle = 2 * math.pi * std.crypto.random.float(f32),
                            .rotation_vel = 2 * math.pi * std.crypto.random.float(f32),
                            .radius = 32,
                            .density = 0.001,
                        },
                        .animation = .{
                            .index = shrapnel_animation,
                            .time_passed = 0,
                            .destroys_entity = true,
                        },
                    });
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

            rb.angle = @mod(
                rb.angle + rb.rotation_vel * delta_s,
                2 * math.pi,
            );
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
                var ship_it = entities.iterator(.{ .ship, .rb });
                while (ship_it.next()) |ship_entity| {
                    const ship = ship_entity.comps.ship;
                    const ship_rb = ship_entity.comps.rb;
                    if (ship_rb.pos.distanceSqrd(rb.pos) <
                        ship_rb.radius * ship_rb.radius + rb.radius * rb.radius)
                    {
                        ship.hp -= damage.hp;

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
                                .radius = 32,
                                .density = 0.001,
                            },
                            .animation = .{
                                .index = shrapnel_animation,
                                .time_passed = 0,
                                .destroys_entity = true,
                            },
                        });

                        entities.remove(damage_entity.handle);
                        continue;
                    }
                }
            }

            rb.angle = rb.vel.angle() + math.pi / 2.0;
        }
    }

    // Update ships
    {
        var it = entities.iterator(.{ .ship, .rb, .input });
        while (it.next()) |entity| {
            const ship = entity.comps.ship;
            const rb = entity.comps.rb;
            const input = entity.comps.input;

            // explode ships that reach 0 hp
            if (ship.hp <= 0) {
                // TODO: take velocity from before impact?
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

                // Create a new ship from this ship's input, and then destroy it!
                _ = game.createShip(entities, ship.player, new_pos, input.*);
                entities.remove(entity.handle);
                continue;
            }

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
                        .radius = 2,
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
            sdlAssertZero(c.SDL_RenderCopyEx(
                renderer,
                frame.sprite.texture,
                null, // source rectangle
                &frame.sprite.toSdlRect(rb.pos),
                toDegrees(rb.angle + frame.angle),
                null, // center of angle
                c.SDL_FLIP_NONE,
            ));
        }
    }

    // Draw ship health bars
    {
        var it = entities.iterator(.{
            .ship,
            .rb,
        });
        while (it.next()) |entity| {
            const ship = entity.comps.ship;
            const rb = entity.comps.rb;

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
        dead_zone: u15 = 10000,
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
            inline for (.{ "positive", "negative" }) |direction| {
                // Check if the keyboard or controller control is activated
                const keyboard_action = @field(self.keyboard_map, field.name);
                const key = if (@field(keyboard_action, direction)) |key|
                    c.SDL_GetKeyboardState(null)[key] == 1
                else
                    false;

                const controller_action = @field(self.controller_map, field.name);
                const button = if (@field(controller_action.buttons, direction)) |button|
                    c.SDL_GameControllerGetButton(self.controller, button) != 0
                else
                    false;
                const axis = if (controller_action.axis) |axis|
                    c.SDL_GameControllerGetAxis(self.controller, axis) > controller_action.dead_zone
                else
                    false;

                // Update the current state
                var current_state = &@field(@field(self.state, field.name), direction);

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
    vel: V,
    /// radians
    angle: f32,
    /// radians per second
    rotation_vel: f32,
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
    };
    const interacts: SymmetricMatrix(Layer, bool) = interacts: {
        var m = SymmetricMatrix(Layer, bool).init(true);
        m.set(.vehicle, .projectile, false);
        break :interacts m;
    };

    collision_damping: f32,
    layer: Layer,
};

const Ship = struct {
    still: Animation.Index,
    accel: Animation.Index,

    /// radians per second
    turn_speed: f32,
    /// pixels per second squared
    thrust: f32,

    hp: f32,
    max_hp: f32,

    class: Class,
    player: u2,

    const Class = enum { ranger, militia };
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

const Game = struct {
    assets: *Assets,

    players: [2]Player,

    shrapnel_animations: [shrapnel_sprite_names.len]Animation.Index,
    explosion_animation: Animation.Index,

    ring_bg: Sprite.Index,
    star_small: Sprite.Index,
    star_large: Sprite.Index,
    planet_red: Sprite.Index,
    bullet_small: Sprite.Index,

    rock_sprite: Sprite.Index,

    ranger_still: Animation.Index,
    ranger_accel: Animation.Index,
    ranger_radius: f32,

    militia_still: Animation.Index,
    militia_accel: Animation.Index,
    militia_radius: f32,

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

    fn createRanger(self: *const @This(), entities: *Entities, player_index: u2, pos: V, input: Input) EntityHandle {
        return entities.create(.{
            .ship = .{
                .class = .ranger,
                .still = self.ranger_still,
                .accel = self.ranger_accel,
                .turn_speed = math.pi * 1.1,
                .thrust = 150,
                .hp = 80,
                .max_hp = 80,
                .player = player_index,
            },
            .rb = .{
                .pos = pos,
                .vel = .{ .x = 0, .y = 0 },
                .angle = -math.pi / 2.0,
                .radius = self.ranger_radius,
                .rotation_vel = 0.0,
                .density = 0.02,
            },
            .collider = .{
                .collision_damping = 0.4,
                .layer = .vehicle,
            },
            .animation = .{
                .index = self.ranger_still,
                .time_passed = 0,
            },
            .turret = .{
                .radius = self.ranger_radius,
                .angle = 0,
                .cooldown = 0,
                .cooldown_amount = 0.2,
                .projectile_speed = 500,
                .projectile_lifetime = 0.5,
                .projectile_damage = 10,
            },
            .input = input,
        });
    }

    fn createMilitia(self: *const @This(), entities: *Entities, player_index: u2, pos: V, input: Input) EntityHandle {
        return entities.create(.{
            .ship = .{
                .class = .militia,
                .still = self.militia_still,
                .accel = self.militia_accel,
                .turn_speed = math.pi * 1.2,
                .thrust = 300,
                .hp = 80,
                .max_hp = 80,
                .player = player_index,
            },
            .rb = .{
                .pos = pos,
                .vel = .{ .x = 0, .y = 0 },
                .angle = -math.pi / 2.0,
                .rotation_vel = 0.0,
                .radius = self.militia_radius,
                .density = 0.02,
            },
            .collider = .{
                .collision_damping = 0.4,
                .layer = .vehicle,
            },
            .animation = .{
                .index = self.militia_still,
                .time_passed = 0,
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

            .ring_bg = ring_bg,
            .star_small = star_small,
            .star_large = star_large,
            .planet_red = planet_red,
            .bullet_small = bullet_small,
            .rock_sprite = rock_sprites[0],

            .ranger_still = ranger_still,
            .ranger_accel = ranger_accel,
            .ranger_radius = ranger_radius,

            .militia_still = militia_still,
            .militia_accel = militia_accel,
            .militia_radius = militia_radius,
        };
    }

    fn createShip(game: *Game, entities: *Entities, player_index: u2, pos: V, input: Input) EntityHandle {
        const player = game.players[player_index];
        return switch (player.ship_progression[player.ship_progression_index]) {
            .ranger => game.createRanger(entities, player_index, pos, input),
            .militia => game.createMilitia(entities, player_index, pos, input),
        };
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
