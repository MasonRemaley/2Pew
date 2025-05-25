const std = @import("std");
const zcs = @import("zcs");
const tracy = @import("tracy");
const Assets = @import("Assets.zig");

const math = std.math;
const tween = zcs.ext.geom.tween;
const lerp = tween.interp.lerp;
const remap = tween.interp.remap;
const remapClamped = tween.interp.remapClamped;

const Game = @import("Game.zig");
const Health = Game.Health;
const RigidBody = Game.RigidBody;
const PlayerIndex = Game.PlayerIndex;
const Spring = Game.Spring;
const Damage = Game.Damage;
const Lifetime = Game.Lifetime;
const Collider = Game.Collider;
const AnimateOnInput = Game.AnimateOnInput;
const GrapplyGun = Game.GrapplyGun;
const FrontShield = Game.FrontShield;
const Ship = Game.Ship;
const TeamIndex = Game.TeamIndex;
const Turret = Game.Turret;
const Hook = Game.Hook;
const GrappleGun = Game.GrappleGun;
const Team = Game.Team;
const Star = Game.Star;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Rotor2 = zcs.ext.geom.Rotor2;
const Vec2 = zcs.ext.geom.Vec2;
const Mat2x3 = zcs.ext.geom.Mat2x3;
const Sprite = Assets.Sprite;
const CmdBuf = zcs.CmdBuf;
const Transform = zcs.ext.Transform2D;
const Animation = Assets.Animation;
const Zone = tracy.Zone;
const randomOnCircle = Game.randomOnCircle;
const randomInCircleBiased = Game.randomInCircleBiased;
const display_center = Game.display_center;
const display_radius = Game.display_radius;

pub fn all(
    es: *Entities,
    cb: *CmdBuf,
    game: *Game,
    delta_s: f32,
) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

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
                .vel = if (rb_opt) |rb| rb.vel else .zero,
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
        rb.vel.addScaled(.{
            .x = input_state.getAxis(.thrust_x),
            .y = input_state.getAxis(.thrust_y),
        }, ship.thrust * ctx.delta_s);
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

fn exec(es: *Entities, cb: *CmdBuf) void {
    Transform.Exec.immediate(es, cb);
}
