const std = @import("std");
const zcs = @import("zcs");
const tracy = @import("tracy");
const gpu = @import("gpu");
const Game = @import("Game.zig");
const Renderer = @import("Renderer.zig");
const Assets = @import("Assets.zig");
const c = @import("c.zig");
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
const geom = zcs.ext.geom;
const tween = geom.tween;
const remap = tween.interp.remap;
const ease = tween.ease;
const Mat2x3 = geom.Mat2x3;
const Vec2 = geom.Vec2;
const Vec3 = geom.Vec3;
const Vec4 = geom.Vec4;
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

const ScreenShakeOptions = struct {
    intensity: f32 = 1.0,
    rotation: bool = true,
};

fn screenShake(game: *const Game, options: ScreenShakeOptions) Mat2x3 {
    // Limits
    const max_intensity = 0.05 * options.intensity;
    const max_rotation = std.math.tau * 0.3 * max_intensity;
    const max_translation = 400.0 * max_intensity;

    // Noise options
    const speed: f32 = 7.0;
    const hurst = 0.0;
    const octaves = 3;

    // Sample the noise
    const t = game.timer.seconds * speed;
    const period = game.timer.period * speed;
    const translate_x_t = t;
    const translate_y_t = t + 50;
    const rotation_t = t + 100;
    const offset_square: Vec2 = .{
        .x = geom.noise.perlinFbm(translate_x_t, .{
            .period = period,
            .hurst = hurst,
            .octaves = octaves,
        }),
        .y = geom.noise.perlinFbm(translate_y_t, .{
            .period = period,
            .hurst = hurst,
            .octaves = octaves,
        }),
    };

    // Map the offset from a square to a circle. Pretty minor difference, but I think it feels
    // slightly nicer.
    const offset: Vec2 = .{
        .x = offset_square.x * @sqrt(1 - 0.5 * offset_square.y * offset_square.y),
        .y = offset_square.y * @sqrt(1 - 0.5 * offset_square.x * offset_square.x),
    };

    // Rotation noise
    const rotation = remap(
        -1,
        1,
        -max_rotation * 0.5,
        max_rotation * 0.5,
        geom.noise.perlinFbm(rotation_t, .{
            .period = period,
            .hurst = hurst,
            .octaves = octaves,
        }),
    );

    // Return the screen shake matrix
    var intensity = game.global_trauma.intensity(null);
    for (game.player_trauma) |trauma| {
        intensity = @max(intensity, trauma.intensity(null));
    }
    var result: Mat2x3 = .identity;
    if (options.rotation) result = result.rotated(.fromAngle(rotation * intensity));
    result = result.translated(offset.scaled(max_translation * intensity));
    return result;
}

fn handheld(game: *const Game) Mat2x3 {
    // Limits
    const max_intensity = 0.025;
    const max_rotation = std.math.tau * 0.075 * max_intensity;
    const max_translation = 400.0 * max_intensity;

    // Noise options
    const speed: f32 = 0.1;
    const hurst = 1.0;
    const octaves = 3;

    // Sample the noise
    const t = game.timer.seconds * speed;
    const period = game.timer.period * speed;
    const translate_x_t = t + 15;
    const translate_y_t = t + 65;
    const rotation_t = t + 115;
    const offset: Vec2 = .{
        .x = geom.noise.perlinFbm(translate_x_t, .{
            .period = period,
            .hurst = hurst,
            .octaves = octaves,
        }),
        .y = geom.noise.perlinFbm(translate_y_t, .{
            .period = period,
            .hurst = hurst,
            .octaves = octaves,
        }),
    };

    // Rotation noise
    const rotation = remap(
        -1,
        1,
        -max_rotation * 0.5,
        max_rotation * 0.5,
        geom.noise.perlinFbm(rotation_t, .{
            .period = period,
            .hurst = hurst,
            .octaves = octaves,
        }),
    );

    // Return the screen shake matrix
    return Mat2x3.identity
        .translated(offset.scaled(max_translation))
        .rotated(.fromAngle(rotation));
}

// TODO(mason): allow passing in const for rendering to make sure no modifications
pub fn all(game: *Game, delta_s: f32) void {
    const zone = Zone.begin(.{ .src = @src() });
    defer zone.end();

    if (game.window_extent.width == 0 or game.window_extent.height == 0) return;

    game.renderer.beginFrame(game.gx);
    defer game.gx.endFrame();

    // Write the entity data
    const entity_writer = b: {
        var scene_writer = game.renderer.scene[game.gx.frame].writer().typed(ubo.Scene);
        var mouse: Vec2 = .zero;
        _ = c.SDL_GetMouseState(&mouse.x, &mouse.y);
        scene_writer.write(.{
            .view_from_world = Mat2x3.identity
                .translated(game.camera)
                .applied(screenShake(game, .{}))
                .applied(handheld(game)),
            .projection_from_view = Mat2x3.ortho(.{
                .left = -display_size.x / 2,
                .right = display_size.x / 2,
                .bottom = -display_size.y / 2,
                .top = display_size.y / 2,
            }),
            .timer = game.timer,
            .mouse = mouse,
        });

        var entity_writer = game.renderer.entities[game.gx.frame].writer().typed(ubo.Entity);

        // Draw the stars
        for (game.stars) |star| {
            const sprite = game.assets.sprite(switch (star.kind) {
                .small => game.star_small,
                .large => game.star_large,
                .planet_red => game.planet_red,
            });
            entity_writer.write(.{
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
            entity_writer.write(.{
                .world_from_model = Mat2x3.identity
                    .translated(.splat(-0.5))
                    .scaled(sprite.size)
                    .translated(display_center),
                .diffuse = sprite.diffuse,
                .recolor = sprite.recolor,
            });
        }

        game.es.forEach("renderAnimations", renderAnimations, .{
            .assets = game.assets,
            .es = game.es,
            .delta_s = delta_s,
            .entity_writer = &entity_writer,
        });

        game.es.forEach("renderHealthBar", renderHealthBar, .{
            .entity_writer = &entity_writer,
        });
        game.es.forEach("renderSprite", renderSprite, .{
            .game = game,
            .entity_writer = &entity_writer,
        });
        game.es.forEach("renderSpring", renderSpring, .{
            .es = game.es,
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
                    entity_writer.write(.{
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
                    entity_writer.write(.{
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

        break :b entity_writer;
    };

    const acquire_result = game.gx.acquireNextImage(game.window_extent);
    const swap_extent = acquire_result.extent;
    const swapchain_image = acquire_result.image;

    // Render the ECS
    {
        const cb: CmdBuf = .init(game.gx, .{ .name = "ECS", .src = @src() });
        defer cb.submit(game.gx, .{});

        cb.barriers(game.gx, .{ .image = &.{
            .undefinedToColorAttachment(.{
                .handle = game.color_buffer.get(&game.renderer.rtp).handle,
                .range = .first,
            }),
        } });
        cb.beginRendering(game.gx, .{
            .color_attachments = &.{
                .init(.{
                    .load_op = .{ .clear_color = .{ 0.0, 0.0, 0.0, 1.0 } },
                    .view = game.color_buffer.get(&game.renderer.rtp).view,
                }),
            },
            .viewport = .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(game.color_buffer.getSizedView(&game.renderer.rtp).extent.width),
                .height = @floatFromInt(game.color_buffer.getSizedView(&game.renderer.rtp).extent.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
            },
            .scissor = .{
                .offset = .zero,
                .extent = game.color_buffer.getSizedView(&game.renderer.rtp).extent,
            },
            .area = .{
                .offset = .zero,
                .extent = game.color_buffer.getSizedView(&game.renderer.rtp).extent,
            },
        });
        defer cb.endRendering(game.gx);

        cb.bindPipeline(game.gx, game.renderer.pipelines.game);
        cb.bindDescSet(
            game.gx,
            game.renderer.pipelines.game,
            game.renderer.ecs_desc_sets[game.gx.frame],
        );
        cb.draw(game.gx, .{
            .vertex_count = 4,
            .instance_count = @intCast(entity_writer.len),
            .first_vertex = 0,
            .first_instance = 0,
        });
    }

    // Do the post processing
    {
        const cb: CmdBuf = .init(game.gx, .{ .name = "Post", .src = @src() });
        defer cb.submit(game.gx, .{ .wait_for_swapchain = true });

        gpu.DescSet.update(game.gx, &.{
            .{
                .set = game.renderer.post_desc_sets[game.gx.frame],
                .binding = Renderer.post_pipeline_layout_options.binding("color_buffer"),
                .value = .{ .storage_image = game.color_buffer.get(&game.renderer.rtp).view },
            },
        });

        cb.barriers(game.gx, .{
            .image = &.{
                .colorAttachmentToGeneral(.{
                    .dst_stages = .{ .fragment = true },
                    .handle = game.color_buffer.get(&game.renderer.rtp).handle,
                    .range = .first,
                }),
                .undefinedToColorAttachment(.{
                    .handle = swapchain_image.handle,
                    .range = .first,
                }),
            },
        });

        {
            // Calculate the letter box
            const game_ar = Game.display_size.x / Game.display_size.y;
            const wind_ar: f32 = @as(f32, @floatFromInt(swap_extent.width)) / @as(f32, @floatFromInt(swap_extent.height));
            const arr = wind_ar / game_ar;
            var size = swap_extent;
            var offset: gpu.Offset2D = .zero;
            if (wind_ar > game_ar) {
                size.width = @intFromFloat(@as(f32, @floatFromInt(swap_extent.width)) / arr);
                offset.x = @intCast((swap_extent.width - size.width) / 2);
            } else {
                size.height = @intFromFloat(@as(f32, @floatFromInt(swap_extent.height)) * arr);
                offset.y = @intCast((swap_extent.height - size.height) / 2);
            }

            // Perform the post processing
            cb.beginRendering(game.gx, .{
                .color_attachments = &.{
                    .init(.{
                        .load_op = .{ .clear_color = .{ 0.0, 0.0, 0.0, 1.0 } },
                        .view = swapchain_image.view,
                    }),
                },
                .viewport = .{
                    .x = @floatFromInt(offset.x),
                    .y = @floatFromInt(offset.y),
                    .width = @floatFromInt(size.width),
                    .height = @floatFromInt(size.height),
                    .min_depth = 0.0,
                    .max_depth = 1.0,
                },
                .scissor = .{
                    .offset = .zero,
                    .extent = swap_extent,
                },
                .area = .{
                    .offset = .zero,
                    .extent = swap_extent,
                },
            });
            defer cb.endRendering(game.gx);
            cb.bindPipeline(game.gx, game.renderer.pipelines.post);
            cb.bindDescSet(
                game.gx,
                game.renderer.pipelines.post,
                game.renderer.post_desc_sets[game.gx.frame],
            );
            cb.draw(game.gx, .{
                .vertex_count = 3,
                .instance_count = 1,
                .first_vertex = 0,
                .first_instance = 0,
            });
        }

        cb.barriers(game.gx, .{ .image = &.{
            .colorAttachmentToPresent(.{
                .handle = swapchain_image.handle,
            }),
        } });
    }
}

fn renderHealthBar(
    ctx: struct { entity_writer: *gpu.Writer.Typed(ubo.Entity) },
    health: *const Health,
    rb: *const RigidBody,
    transform: *const Transform,
) void {
    if (health.hp >= health.max_hp) return;

    const health_bar_size: Vec2 = .{ .x = 32, .y = 4 };
    var start = transform.getWorldPos().minus(health_bar_size.scaled(0.5)).floored();
    start.y += rb.radius + health_bar_size.y;

    ctx.entity_writer.write(.{
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
    ctx.entity_writer.write(.{
        .world_from_model = Mat2x3.identity
            .scaled(health_bar_size.compProd(.{ .x = hp_percent, .y = 1.0 }))
            .translated(start),
        .color = color,
    });
}

fn renderSprite(
    ctx: struct {
        game: *const Game,
        entity_writer: *gpu.Writer.Typed(ubo.Entity),
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
    ctx.entity_writer.write(.{
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
        entity_writer: *gpu.Writer.Typed(ubo.Entity),
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
        ctx.entity_writer.write(.{
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
