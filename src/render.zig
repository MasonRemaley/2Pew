const std = @import("std");
const zcs = @import("zcs");
const tracy = @import("tracy");
const gpu = @import("gpu");
const Game = @import("Game.zig");
const Renderer = @import("Renderer.zig");
const Assets = @import("Assets.zig");
const c = @import("c.zig").c;
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
    colors.floatToUnorm(ubo.Color, .{
        0.063,
        0.486,
        0.769,
        1.0,
    }),
    colors.floatToUnorm(ubo.Color, .{
        0.929,
        0.824,
        0.251,
        1.0,
    }),
    colors.floatToUnorm(ubo.Color, .{
        0.878,
        0.251,
        0.929,
        1.0,
    }),
    colors.floatToUnorm(ubo.Color, .{
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

    const color_buffer = game.color_buffer.get(&game.renderer.rtp);
    const color_buffer_msaa = game.color_buffer_msaa.get(&game.renderer.rtp);
    const depth_buffer = game.depth_buffer.get(&game.renderer.rtp_depth);
    const blurred: [2]gpu.ext.RenderTarget(.color).State = .{
        game.blurred[0].get(&game.renderer.rtp),
        game.blurred[1].get(&game.renderer.rtp),
    };
    const composite = game.composite.get(&game.renderer.rtp);

    {
        game.renderer.beginFrame(game.gx);
        defer game.gx.endFrame(.{ .present = .{
            .handle = composite.image.handle,
            .src_extent = composite.extent,
            .surface_extent = game.window_extent,
            .range = .first,
            .filter = .linear,
        } });

        // Write the entity data
        var effect_scale: f32 = 1.0;
        const entity_writer = b: {
            var scene_writer = game.renderer.scene[game.gx.frame].writer().typed(ubo.Scene);
            var mouse: Vec2 = .zero;
            _ = c.SDL_GetMouseState(&mouse.x, &mouse.y);

            const projection_from_view = pfv: {
                // Project the scene so that the 1920x1080 virtual coordinates are centered and
                // fill the screen as much as they can without getting clipped one either dimension.
                // This lets us design the game for 16:9, but still render stars and other stuff
                // outside the 16:9 bounds for other aspect ratios which avoids needing to letterbox
                // while keeping the game logic simple.
                const wind_extent: Vec2 = .{
                    .x = @floatFromInt(game.window_extent.width),
                    .y = @floatFromInt(game.window_extent.height),
                };
                const wind_ar: f32 = wind_extent.x / wind_extent.y;
                const game_ar = Game.display_size.x / Game.display_size.y;
                var proj_size: Vec2 = Game.display_size;
                if (wind_ar > game_ar) {
                    effect_scale = wind_extent.x / Game.display_size.x;
                    proj_size.x = proj_size.y * wind_ar;
                } else {
                    effect_scale = wind_extent.y / Game.display_size.y;
                    proj_size.y = proj_size.x / wind_ar;
                }
                break :pfv Mat2x3.ortho(.{
                    .left = -proj_size.x / 2,
                    .right = proj_size.x / 2,
                    .bottom = -proj_size.y / 2,
                    .top = proj_size.y / 2,
                });
            };

            scene_writer.write(.{
                .view_from_world = Mat2x3.identity
                    .translated(game.camera)
                    .applied(screenShake(game, .{}))
                    .applied(handheld(game)),
                .projection_from_view = projection_from_view,
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
                        .translated(star.pos),
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

            var entities_len_writer = game.renderer.entities_len[game.gx.frame].writer().typed(u32);
            entities_len_writer.write(@intCast(entity_writer.len));

            break :b entity_writer;
        };

        // Update the render targets
        {
            var updates: std.ArrayListUnmanaged(gpu.DescSet.Update) = .initBuffer(game.renderer.rt_update_buf);

            for (game.renderer.rtp.images.items, game.renderer.rtp.info.items, 0..) |image, info, i| {
                if (info.image.usage.storage) {
                    if (updates.items.len >= updates.capacity) @panic("OOB");
                    updates.appendAssumeCapacity(.{
                        .set = game.renderer.desc_sets[game.gx.frame],
                        .binding = Renderer.pipeline_layout_options.binding("rt_storage"),
                        .value = .{ .storage_image = image.view },
                        .index = @intCast(i),
                    });
                }
            }

            for (game.renderer.rtp.images.items, game.renderer.rtp.info.items, 0..) |image, info, i| {
                if (info.image.usage.sampled) {
                    if (updates.items.len >= updates.capacity) @panic("OOB");
                    updates.appendAssumeCapacity(.{
                        .set = game.renderer.desc_sets[game.gx.frame],
                        .binding = Renderer.pipeline_layout_options.binding("rt_sampled"),
                        .value = .{ .sampled_image = image.view },
                        .index = @intCast(i),
                    });
                }
            }

            game.gx.updateDescSets(updates.items);
        }

        const cb: CmdBuf = .init(game.gx, .{ .name = "Render", .src = @src() });

        cb.bindDescSet(game.gx, .{
            .bind_points = .{
                .graphics = true,
                .compute = true,
            },
            .layout = game.renderer.pipeline_layout.handle,
            .set = game.renderer.desc_sets[game.gx.frame],
        });
        if (game.gx.validation.gte(.fast)) {
            // If validation layers are on, fill the push constant data with undefined so that we
            // don't get warnings about unused fields not being set
            cb.pushConstant([32]u32, game.gx, .{
                .pipeline_layout = game.renderer.pipeline_layout.handle,
                .stages = .{ .compute = true },
                .data = &undefined,
            });
        }

        // Render the ECS
        {
            cb.beginZone(game.gx, .{ .name = "ECS", .src = @src() });
            defer cb.endZone(game.gx);

            cb.barriers(game.gx, .{
                .image = &.{
                    .undefinedToColorAttachment(.{
                        .handle = color_buffer.image.handle,
                        .src_stages = .{ .top_of_pipe = true },
                        .range = .first,
                    }),
                    .undefinedToColorAttachment(.{
                        .handle = color_buffer.image.handle,
                        .src_stages = .{ .top_of_pipe = true },
                        .range = .first,
                    }),
                    .undefinedToDepthStencilAttachmentAfterWrite(.{
                        .handle = depth_buffer.image.handle,
                        .range = .first,
                        .aspect = .{ .depth = true },
                    }),
                },
            });
            cb.beginRendering(game.gx, .{
                .color_attachments = &.{
                    .init(.{
                        .load_op = .{ .clear_color = .{ 0.0, 0.0, 0.0, 0.0 } },
                        .view = color_buffer_msaa.image.view,
                        .resolve_view = color_buffer.image.view,
                        .resolve_mode = .average,
                        .store_op = .dont_care,
                    }),
                },
                .depth_attachment = .init(.{
                    .load_op = .{
                        .clear_depth_stencil = .{
                            .depth = 0.0,
                            .stencil = 0.0,
                        },
                    },
                    .view = depth_buffer.image.view,
                    .resolve_view = null,
                    .resolve_mode = .none,
                    .store_op = .dont_care,
                }),
                .viewport = .{
                    .x = 0,
                    .y = 0,
                    .width = @floatFromInt(color_buffer.extent.width),
                    .height = @floatFromInt(color_buffer.extent.height),
                    .min_depth = 0.0,
                    .max_depth = 1.0,
                },
                .scissor = .{
                    .offset = .zero,
                    .extent = color_buffer.extent,
                },
                .area = .{
                    .offset = .zero,
                    .extent = color_buffer.extent,
                },
            });
            defer cb.endRendering(game.gx);

            cb.bindPipeline(game.gx, .{
                .bind_point = .graphics,
                .pipeline = game.renderer.pipelines.game,
            });
            cb.draw(game.gx, .{
                .vertex_count = 4,
                .instance_count = @intCast(entity_writer.len),
                .first_vertex = 0,
                .first_instance = 0,
            });
        }

        // Do the post processing
        var blur_in_index: u32 = 0;
        var blur_out_index: u32 = 1;
        {
            cb.beginZone(game.gx, .{ .name = "Post", .src = @src() });
            defer cb.endZone(game.gx);

            // Blur
            {
                cb.beginZone(game.gx, .{ .name = "Blur", .src = @src() });
                defer cb.endZone(game.gx);

                {
                    cb.beginZone(game.gx, .{ .name = "Downscale", .src = @src() });
                    cb.endZone(game.gx);

                    cb.barriers(game.gx, .{
                        .image = &.{
                            .colorAttachmentToBlitSrc(.{
                                .handle = color_buffer.image.handle,
                                .range = .first,
                            }),
                            .undefinedToBlitDst(.{
                                .handle = blurred[blur_out_index].image.handle,
                                .range = .first,
                                .src_stages = .{ .top_of_pipe = true },
                                .aspect = .{ .color = true },
                            }),
                        },
                    });

                    cb.blit(game.gx, .{
                        .src = color_buffer.image.handle,
                        .dst = blurred[blur_out_index].image.handle,
                        .regions = &.{
                            .init(.{
                                .src = .{
                                    .mip_level = 0,
                                    .base_array_layer = 0,
                                    .array_layers = 1,
                                    .volume = .fromExtent2D(color_buffer.extent),
                                },
                                .dst = .{
                                    .mip_level = 0,
                                    .base_array_layer = 0,
                                    .array_layers = 1,
                                    .volume = .fromExtent2D(blurred[blur_out_index].extent),
                                },
                                .aspect = .{ .color = true },
                            }),
                        },
                        .filter = .linear,
                    });

                    std.mem.swap(u32, &blur_in_index, &blur_out_index);
                }

                if (game.renderer.moving_avg_blur) {
                    cb.beginZone(game.gx, .{ .name = "Moving Average Gaussian", .src = @src() });
                    defer cb.endZone(game.gx);

                    const radius: i32 = @intFromFloat(@round(2 * effect_scale));
                    cb.bindPipeline(game.gx, .{
                        .bind_point = .compute,
                        .pipeline = game.renderer.pipelines.box_blur_moving_avg,
                    });

                    for (0..3) |i| {
                        cb.beginZone(game.gx, .{ .name = "Blur X", .src = @src() });
                        defer cb.endZone(game.gx);

                        cb.barriers(game.gx, .{
                            .image = &.{
                                b: {
                                    if (i == 0) {
                                        break :b .blitDstToGeneral(.{
                                            .handle = blurred[blur_in_index].image.handle,
                                            .dst_stages = .{ .compute = true },
                                            .dst_access = .{ .read = true },
                                            .range = .first,
                                            .aspect = .{ .color = true },
                                        });
                                    } else {
                                        break :b .generalToGeneral(.{
                                            .handle = blurred[blur_in_index].image.handle,
                                            .src_stages = .{ .compute = true },
                                            .src_access = .{ .write = true },
                                            .dst_stages = .{ .compute = true },
                                            .dst_access = .{ .read = true },
                                            .range = .first,
                                            .aspect = .{ .color = true },
                                        });
                                    }
                                },
                                .undefinedToGeneral(.{
                                    .handle = blurred[blur_out_index].image.handle,
                                    .src_stages = .{ .top_of_pipe = true },
                                    .dst_stages = .{ .compute = true },
                                    .dst_access = .{ .write = true },
                                    .range = .first,
                                    .aspect = .{ .color = true },
                                }),
                            },
                        });

                        cb.pushConstant(Renderer.interface.pp_bbma_PushConstants, game.gx, .{
                            .pipeline_layout = game.renderer.pipeline_layout.handle,
                            .stages = .{ .compute = true },
                            .data = &.{
                                .input_rt_storage_image_rba8_r_index = @intFromEnum(game.blurred[blur_in_index]),
                                .output_rt_storage_image_any_w = @intFromEnum(game.blurred[blur_out_index]),
                                .radius = radius,
                                .horizontal = @intFromBool(true),
                            },
                        });
                        cb.dispatch(game.gx, @bitCast(Renderer.interface.PP_BBMA_DSIZE(.{
                            .x = blurred[0].extent.width,
                            .y = blurred[0].extent.height,
                        })));

                        std.mem.swap(u32, &blur_in_index, &blur_out_index);
                    }

                    for (0..3) |_| {
                        cb.beginZone(game.gx, .{ .name = "Blur Y", .src = @src() });
                        defer cb.endZone(game.gx);

                        cb.barriers(game.gx, .{
                            .image = &.{
                                .generalToGeneral(.{
                                    .handle = blurred[blur_in_index].image.handle,
                                    .src_stages = .{ .compute = true },
                                    .src_access = .{ .write = true },
                                    .dst_stages = .{ .compute = true },
                                    .dst_access = .{ .read = true },
                                    .range = .first,
                                    .aspect = .{ .color = true },
                                }),
                                .undefinedToGeneral(.{
                                    .handle = blurred[blur_out_index].image.handle,
                                    .src_stages = .{ .top_of_pipe = true },
                                    .dst_stages = .{ .compute = true },
                                    .dst_access = .{ .write = true },
                                    .range = .first,
                                    .aspect = .{ .color = true },
                                }),
                            },
                        });

                        cb.pushConstant(Renderer.interface.pp_bbma_PushConstants, game.gx, .{
                            .pipeline_layout = game.renderer.pipeline_layout.handle,
                            .stages = .{ .compute = true },
                            .data = &.{
                                .input_rt_storage_image_rba8_r_index = @intFromEnum(game.blurred[blur_in_index]),
                                .output_rt_storage_image_any_w = @intFromEnum(game.blurred[blur_out_index]),
                                .radius = radius,
                                .horizontal = @intFromBool(false),
                            },
                        });
                        cb.dispatch(game.gx, @bitCast(Renderer.interface.PP_BBMA_DSIZE(.{
                            .x = blurred[0].extent.height,
                            .y = blurred[0].extent.width,
                        })));

                        std.mem.swap(u32, &blur_in_index, &blur_out_index);
                    }
                } else {
                    cb.beginZone(game.gx, .{ .name = "Linear Gaussian", .src = @src() });
                    defer cb.endZone(game.gx);

                    cb.bindPipeline(game.gx, .{
                        .bind_point = .compute,
                        .pipeline = game.renderer.pipelines.linear_convolve,
                    });
                    var blur_args: Renderer.interface.pp_lc_PushConstants = .{
                        .pass = .{
                            .input_rt_texture_index = @intFromEnum(game.blurred[blur_in_index]),
                            .output_rt_storage_image_any_w_index = @intFromEnum(game.blurred[blur_out_index]),
                            .horizontal = @intFromBool(true),
                        },
                        .radius = 0,
                        .weights = undefined,
                        .offsets = undefined,
                    };
                    const linear = gpu.ext.gaussian.linear(.{
                        .weights_buf = &blur_args.weights,
                        .offsets_buf = &blur_args.offsets,
                        .sigma = 5 * effect_scale,
                    });
                    blur_args.radius = @intCast(linear.weights.len);

                    {
                        cb.beginZone(game.gx, .{ .name = "X", .src = @src() });
                        defer cb.endZone(game.gx);

                        cb.barriers(game.gx, .{
                            .image = &.{
                                .blitDstToReadOnly(.{
                                    .handle = blurred[blur_in_index].image.handle,
                                    .dst_stages = .{ .compute = true },
                                    .range = .first,
                                    .aspect = .{ .color = true },
                                }),
                                .undefinedToGeneral(.{
                                    .handle = blurred[blur_out_index].image.handle,
                                    .src_stages = .{ .top_of_pipe = true },
                                    .dst_stages = .{ .compute = true },
                                    .dst_access = .{ .write = true },
                                    .range = .first,
                                    .aspect = .{ .color = true },
                                }),
                            },
                        });

                        cb.pushConstant(Renderer.interface.pp_lc_PushConstants, game.gx, .{
                            .pipeline_layout = game.renderer.pipeline_layout.handle,
                            .stages = .{ .compute = true },
                            .data = &blur_args,
                        });
                        cb.dispatch(game.gx, @bitCast(Renderer.interface.PP_LC_DSIZE(.{
                            .x = blurred[0].extent.width,
                            .y = blurred[0].extent.height,
                        })));

                        std.mem.swap(u32, &blur_in_index, &blur_out_index);
                    }

                    {
                        cb.beginZone(game.gx, .{ .name = "Y", .src = @src() });
                        defer cb.endZone(game.gx);

                        cb.barriers(game.gx, .{
                            .image = &.{
                                .generalToReadOnly(.{
                                    .handle = blurred[blur_in_index].image.handle,
                                    .src_stages = .{ .compute = true },
                                    .src_access = .{ .write = true },
                                    .dst_stages = .{ .compute = true },
                                    .range = .first,
                                    .aspect = .{ .color = true },
                                }),
                                .undefinedToGeneral(.{
                                    .handle = blurred[blur_out_index].image.handle,
                                    .src_stages = .{ .compute = true },
                                    .dst_stages = .{ .compute = true },
                                    .dst_access = .{ .write = true },
                                    .range = .first,
                                    .aspect = .{ .color = true },
                                }),
                            },
                        });
                        blur_args.pass = .{
                            .input_rt_texture_index = @intFromEnum(game.blurred[blur_in_index]),
                            .output_rt_storage_image_any_w_index = @intFromEnum(game.blurred[blur_out_index]),
                            .horizontal = @intFromBool(false),
                        };
                        cb.pushConstantField(Renderer.interface.pp_lc_PushConstants, "pass", game.gx, .{
                            .pipeline_layout = game.renderer.pipeline_layout.handle,
                            .stages = .{ .compute = true },
                            .data = &blur_args.pass,
                        });
                        cb.dispatch(game.gx, @bitCast(Renderer.interface.PP_LC_DSIZE(.{
                            .x = blurred[0].extent.width,
                            .y = blurred[0].extent.height,
                        })));

                        std.mem.swap(u32, &blur_in_index, &blur_out_index);
                    }
                }
            }

            // Composite
            {
                cb.beginZone(game.gx, .{ .name = "Composite", .src = @src() });
                defer cb.endZone(game.gx);

                cb.barriers(game.gx, .{
                    .image = &.{
                        .blitSrcToGeneral(.{
                            .handle = color_buffer.image.handle,
                            .dst_stages = .{ .compute = true },
                            .dst_access = .{ .read = true },
                            .range = .first,
                            .aspect = .{ .color = true },
                        }),
                        .generalToGeneral(.{
                            .handle = blurred[blur_in_index].image.handle,
                            .src_stages = .{ .compute = true },
                            .src_access = .{ .write = true },
                            .dst_stages = .{ .compute = true },
                            .dst_access = .{ .read = true },
                            .range = .first,
                            .aspect = .{ .color = true },
                        }),
                        .undefinedToGeneralAfterBlit(.{
                            .handle = composite.image.handle,
                            .dst_stages = .{ .compute = true },
                            .dst_access = .{ .write = true },
                            .range = .first,
                            .aspect = .{ .color = true },
                        }),
                    },
                });
                cb.bindPipeline(game.gx, .{
                    .bind_point = .compute,
                    .pipeline = game.renderer.pipelines.composite,
                });
                cb.pushConstant(Renderer.interface.pp_c_PushConstants, game.gx, .{
                    .pipeline_layout = game.renderer.pipeline_layout.handle,
                    .stages = .{ .compute = true },
                    .data = &.{
                        .surface_format = game.gx.device.surface_format.userdata,
                        .color_buffer_index = @intFromEnum(game.color_buffer),
                        .blurred_index = @intFromEnum(game.blurred[blur_in_index]),
                        .composite_index = @intFromEnum(game.composite),
                    },
                });
                cb.dispatch(game.gx, @bitCast(Renderer.interface.PP_C_DSIZE(.{
                    .x = composite.extent.width,
                    .y = composite.extent.height,
                })));
            }

            // Get ready for presentation
            cb.barriers(game.gx, .{ .image = &.{
                .generalToBlitSrc(.{
                    .handle = composite.image.handle,
                    .src_stages = .{ .compute = true },
                    .range = .first,
                    .aspect = .{ .color = true },
                }),
            } });
        }

        // Submit all the work at once to reduce driver overhead
        cb.end(game.gx);
        game.gx.submit(&.{cb});
    }

    if (game.renderer.rtp.suboptimal(&game.resize_timer, game.window_extent) or
        game.renderer.rtp_depth.suboptimal(&game.resize_timer, game.window_extent))
    {
        game.gx.waitIdle();
        game.renderer.rtp.recreate(game.gx, game.window_extent);
        game.renderer.rtp_depth.recreate(game.gx, game.window_extent);
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
        colors.floatToUnorm(ubo.Color, .{ 0.000, 0.580, 0.075, 1 })
    else if (health.regen_cooldown_s > 0.0)
        colors.floatToUnorm(ubo.Color, .{ 0.886, 0.000, 0.012, 1 })
    else
        colors.floatToUnorm(ubo.Color, .{ 1.000, 0.490, 0.012, 1 });
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
