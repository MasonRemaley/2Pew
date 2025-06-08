const std = @import("std");
const zcs = @import("zcs");
const tracy = @import("tracy");
const gpu = @import("gpu");
const Game = @import("Game.zig");
const Renderer = @import("Renderer.zig");
const Assets = @import("Assets.zig");
const Entities = zcs.Entities;

const ubo = Renderer.ubo;
const colors = gpu.ext.colors;
const display_size = Game.display_size;
const display_center = Game.display_center;

const Entity = zcs.Entity;
const Node = zcs.ext.Node;
const Sprite = Assets.Sprite;
const Animation = Assets.Animation;
const Zone = tracy.Zone;
const Mat2x3 = zcs.ext.geom.Mat2x3;
const Vec2 = zcs.ext.geom.Vec2;
const Transform = zcs.ext.Transform2D;
const CmdBuf = gpu.CmdBuf;
const Health = Game.Health;
const RigidBody = Game.RigidBody;
const TeamIndex = Game.TeamIndex;
const Spring = Game.Spring;

const team_colors: [4]ubo.Color = .{
    colors.srgbToLinearUnorm(ubo.Color, [4]f32, .{
        0.063,
        0.486,
        0.769,
        1.0,
    }),
    colors.srgbToLinearUnorm(ubo.Color, [4]f32, .{
        0.929,
        0.824,
        0.251,
        1.0,
    }),
    colors.srgbToLinearUnorm(ubo.Color, [4]f32, .{
        0.878,
        0.251,
        0.929,
        1.0,
    }),
    colors.srgbToLinearUnorm(ubo.Color, [4]f32, .{
        0.325,
        0.929,
        0.251,
        1.0,
    }),
};

// TODO(mason): allow passing in const for rendering to make sure no modifications
pub fn all(es: *Entities, game: *Game, delta_s: f32) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    // Get this frame's storage writers
    game.renderer.beginFrame(game.gx);

    var scene_writer = game.renderer.scene[game.gx.frame].writer().typed(ubo.Scene);
    scene_writer.write(.{
        .view_from_world = Mat2x3.ortho(.{
            .left = 0,
            .right = display_size.x,
            .bottom = 0,
            .top = display_size.y,
        }).times(.translation(game.camera.negated())),
        .time = game.time.seconds,
    });

    var instances = game.renderer.sprites[game.gx.frame].writer().typed(ubo.Instance);

    // Draw the stars
    for (game.stars) |star| {
        const sprite = game.assets.sprite(switch (star.kind) {
            .small => game.star_small,
            .large => game.star_large,
            .planet_red => game.planet_red,
        });
        instances.write(.{
            .world_from_model = Mat2x3.identity
                .translated(.splat(-0.5))
                .scaled(sprite.size)
                .translated(.{ .x = @floatFromInt(star.x), .y = @floatFromInt(star.y) }),
            .diffuse = sprite.diffuse,
            .recolor = sprite.recolor,
        });
    }

    // Draw the ring
    {
        const sprite = game.assets.sprite(game.ring_bg);
        instances.write(.{
            .world_from_model = Mat2x3.identity
                .translated(.splat(-0.5))
                .scaled(sprite.size)
                .translated(display_center),
            .diffuse = sprite.diffuse,
            .recolor = sprite.recolor,
        });
    }

    es.forEach("renderAnimations", renderAnimations, .{
        .assets = game.assets,
        .es = es,
        .delta_s = delta_s,
        .instances = &instances,
    });

    es.forEach("renderHealthBar", renderHealthBar, .{
        .instances = &instances,
    });
    es.forEach("renderSprite", renderSprite, .{
        .game = game,
        .instances = &instances,
    });
    es.forEach("renderSpring", renderSpring, .{
        .es = es,
    });

    // Draw the ships in the bank.
    {
        const row_height = 64;
        const col_width = 64;
        const top_left: Vec2 = .splat(20);

        for (game.teams, 0..) |team, team_index| {
            {
                const sprite = game.assets.sprite(game.particle);
                const pos = top_left.plus(.{
                    .x = col_width * @as(f32, @floatFromInt(team_index)),
                    .y = 0,
                });
                instances.write(.{
                    .world_from_model = Mat2x3.identity
                        .translated(.splat(-0.5))
                        .scaled(sprite.size)
                        .translated(pos),
                    .diffuse = sprite.diffuse,
                    .recolor = sprite.recolor,
                    .color = team_colors[team_index],
                });
            }
            for (team.ship_progression, 0..) |class, display_prog_index| {
                const dead = team.ship_progression_index > display_prog_index;
                if (dead) continue;

                const sprite = game.assets.sprite(game.shipLifeSprite(class));
                const pos = top_left.plus(.{
                    .x = col_width * @as(f32, @floatFromInt(team_index)),
                    .y = display_size.y - row_height * @as(f32, @floatFromInt(display_prog_index)),
                });
                instances.write(.{
                    .world_from_model = Mat2x3.identity
                        .translated(.splat(-0.5))
                        .scaled(sprite.size.scaled(0.5))
                        .translated(pos),
                    .diffuse = sprite.diffuse,
                    .recolor = sprite.recolor,
                    .color = team_colors[team_index],
                });
            }
        }
    }

    const framebuf = game.gx.acquireNextImage(.{
        .width = display_size.x,
        .height = display_size.y,
    });
    const render_game: CmdBuf = .init(game.gx, .{
        .name = "Render Game",
        .src = @src(),
    });
    render_game.beginRendering(game.gx, .{
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
            .offset = .zero,
            .extent = framebuf.extent,
        },
        .area = .{
            .offset = .zero,
            .extent = framebuf.extent,
        },
    });
    render_game.bindPipeline(game.gx, game.renderer.pipeline);
    render_game.bindDescSet(game.gx, game.renderer.pipeline, game.renderer.desc_sets[game.gx.frame]);
    render_game.draw(game.gx, .{
        .vertex_count = 4,
        .instance_count = @intCast(instances.len),
        .first_vertex = 0,
        .first_instance = 0,
    });
    render_game.endRendering(game.gx);
    render_game.submit(game.gx);

    game.gx.endFrame(.{});
}

fn renderHealthBar(
    ctx: struct { instances: *gpu.Writer.Typed(ubo.Instance) },
    health: *const Health,
    rb: *const RigidBody,
    transform: *const Transform,
) void {
    if (health.hp >= health.max_hp) return;

    const health_bar_size: Vec2 = .{ .x = 32, .y = 4 };
    var start = transform.getWorldPos().minus(health_bar_size.scaled(0.5)).floored();
    start.y += rb.radius + health_bar_size.y;

    ctx.instances.write(.{
        .world_from_model = Mat2x3.identity
            .scaled(health_bar_size.plus(.splat(2)))
            .translated(start.minus(.splat(1))),
        .color = .white,
    });
    const hp_percent = health.hp / health.max_hp;
    const color: ubo.Color = if (hp_percent >= health.regen_ratio)
        colors.srgbToLinearUnorm(ubo.Color, [4]f32, .{ 0.000, 0.580, 0.075, 1 })
    else if (health.regen_cooldown_s > 0.0)
        colors.srgbToLinearUnorm(ubo.Color, [4]f32, .{ 0.886, 0.000, 0.012, 1 })
    else
        colors.srgbToLinearUnorm(ubo.Color, [4]f32, .{ 1.000, 0.490, 0.012, 1 });
    ctx.instances.write(.{
        .world_from_model = Mat2x3.identity
            .scaled(health_bar_size.compProd(.{ .x = hp_percent, .y = 1.0 }))
            .translated(start),
        .color = color,
    });
}

fn renderSprite(
    ctx: struct {
        game: *const Game,
        instances: *gpu.Writer.Typed(ubo.Instance),
    },
    sprite_index: *const Sprite.Index,
    rb_opt: ?*const RigidBody,
    transform: *const Transform,
    team_index: ?*const TeamIndex,
) void {
    const assets = ctx.game.assets;
    // TODO(mason): sort draw calls somehow (can the sdl renderer do depth buffers?)
    const sprite = assets.sprite(sprite_index.*);
    const unscaled_sprite_size = sprite.size;
    const sprite_radius = (unscaled_sprite_size.x + unscaled_sprite_size.y) / 4.0;
    const size_coefficient = if (rb_opt) |rb| rb.radius / sprite_radius else 1.0;
    const sprite_size = unscaled_sprite_size.scaled(size_coefficient);
    ctx.instances.write(.{
        .world_from_model = Mat2x3.identity
            .translated(.splat(-0.5))
            .scaled(sprite_size)
            .applied(transform.world_from_model),
        .diffuse = sprite.diffuse,
        .recolor = sprite.recolor,
        .color = if (team_index) |ti| team_colors[@intFromEnum(ti.*)] else .white,
    });
}

fn renderSpring(ctx: struct { es: *const Entities }, spring: *const Spring) void {
    const es = ctx.es;
    const start = (spring.start.get(es, Transform) orelse return).getWorldPos();
    const end = (spring.end.get(es, Transform) orelse return).getWorldPos();
    // TODO(mason): the SDL renderer drew hese as lines, but we wanted to switch to a themed grapple
    // effect that has its own components and gets drawn from spring start to end.
    _ = start;
    _ = end;
}

fn renderAnimations(
    ctx: struct {
        assets: *const Assets,
        es: *Entities,
        delta_s: f32,
        instances: *gpu.Writer.Typed(ubo.Instance),
    },
    entity: Entity,
    rb: *const RigidBody,
    transform: *const Transform,
    animation: *Animation.Playback,
    team_index: ?*const TeamIndex,
) void {
    const es = ctx.es;
    const assets = ctx.assets;
    const delta_s = ctx.delta_s;

    // Skip rendering if flashing, or if any parent is flashing.
    //
    // We should probably make the sprites half opacity instead of turning them off when
    // flashing for a less jarring effect, but that is difficult right now w/ SDL as our
    // renderer.
    var flash = false;
    b: {
        var curr = entity;
        while (true) {
            if (curr.get(es, Health)) |health| {
                if (health.invulnerable_s > 0.0) {
                    var flashes_ps: f32 = 2;
                    if (health.invulnerable_s < 0.25 * std.math.round(Health.max_invulnerable_s * flashes_ps) / flashes_ps) {
                        flashes_ps = 4;
                    }
                    if (@sin(flashes_ps * std.math.tau * health.invulnerable_s) > 0.0) {
                        flash = true;
                        break :b;
                    }
                }
            }

            if (curr.get(es, Node)) |node| {
                if (node.parent.unwrap()) |parent| {
                    curr = parent;
                    continue;
                }
            }

            break :b;
        }
    }

    if (animation.index != .none) {
        var color: ubo.Color = if (team_index) |ti| team_colors[@intFromEnum(ti.*)] else .white;
        if (flash) color.a = 0;
        const frame = animation.advance(assets, delta_s);
        const sprite = assets.sprite(frame.sprite);
        const unscaled_sprite_size = sprite.size;
        const sprite_radius = (unscaled_sprite_size.x + unscaled_sprite_size.y) / 4.0;
        const size_coefficient = rb.radius / sprite_radius;
        const sprite_size = unscaled_sprite_size.scaled(size_coefficient);
        ctx.instances.write(.{
            .world_from_model = Mat2x3.identity
                .translated(.splat(-0.5))
                .rotated(.fromAngle(frame.angle))
                .scaled(sprite_size)
                .applied(transform.world_from_model),
            .diffuse = sprite.diffuse,
            .recolor = sprite.recolor,
            .color = color,
        });
    }
}
