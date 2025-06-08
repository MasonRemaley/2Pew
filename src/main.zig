const std = @import("std");
const c = @import("c.zig");
const panic = std.debug.panic;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const math = std.math;
const zcs = @import("zcs");
const typeId = zcs.typeId;
const Entities = zcs.Entities;
const Entity = zcs.Entity;
const Component = zcs.Component;
const CmdBuf = zcs.CmdBuf;
const Node = zcs.ext.Node;
const Vec2 = zcs.ext.geom.Vec2;
const gpu = @import("gpu");
const VkBackend = @import("VkBackend");
const Gx = gpu.Gx;
const build = @import("build.zig.zon");
const logger = @import("logger");
const Logger = logger.Logger(.{ .history = .none });
const structopt = @import("structopt");
const Command = structopt.Command;
const NamedArg = structopt.NamedArg;
const log = std.log.scoped(build.name);
const ImageUploadQueue = gpu.ext.ImageUploadQueue;
const Renderer = @import("Renderer.zig");
const ubo = Renderer.ubo;
const SpriteRenderer = Renderer.SpriteRenderer;
const tween = zcs.ext.geom.tween;
const lerp = tween.interp.lerp;
const tracy = @import("tracy");
const Zone = tracy.Zone;
const Assets = @import("Assets.zig");
const render = @import("render.zig");
const update = @import("update.zig");
const Game = @import("Game.zig");

pub const tracy_impl = @import("tracy_impl");

pub const std_options: std.Options = .{
    .logFn = Logger.logFn,
    .log_level = .info,
};

pub const gpu_options: gpu.Options = .{
    .Backend = VkBackend,
    .update_desc_sets_buf_len = 1000,
};

const command: Command = .{
    .name = @tagName(build.name),
    .named_args = &.{
        NamedArg.init(Gx.Options.DebugMode, .{
            .long = "gpu-dbg",
            .default = .{ .value = if (builtin.mode == .Debug) .validate else .none },
        }),
        // Just shaders for now
        NamedArg.init(bool, .{
            .long = "hot-swap",
            .default = .{ .value = if (builtin.mode == .Debug) true else false },
        }),
    },
};

pub fn main() !void {
    c.SDL_SetLogPriorities(c.SDL_LOG_PRIORITY_TRACE);
    c.SDL_SetLogOutputFunction(&sdlLogCallback, null);

    // Allocator setup
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    var tracy_allocator: tracy.Allocator = .{
        .pool_name = "gpa",
        .parent = gpa.allocator(),
    };
    const allocator = tracy_allocator.allocator();

    const args = try command.parse(allocator);
    defer command.parseFree(args);

    // Init SDL
    if (!c.SDL_SetHintWithPriority(
        c.SDL_HINT_NO_SIGNAL_HANDLERS,
        "1",
        c.SDL_HINT_OVERRIDE,
    )) {
        log.err("SDL_SetHintWithPriority failed: {?s}", .{c.SDL_GetError()});
    }
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMEPAD | c.SDL_INIT_AUDIO)) {
        panic("SDL_Init failed: {?s}\n", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    std.log.scoped(.sdl).info("video driver: {s}", .{c.SDL_GetCurrentVideoDriver() orelse @as([*c]const u8, "null")});
    std.log.scoped(.sdl).info("audio driver: {s}", .{c.SDL_GetCurrentAudioDriver() orelse @as([*c]const u8, "null")});

    const window_mode = switch (builtin.mode) {
        .Debug => c.SDL_WINDOW_RESIZABLE,
        else => c.SDL_WINDOW_FULLSCREEN,
    };

    const screen = c.SDL_CreateWindow(
        @tagName(build.name),
        Game.display_size.x,
        Game.display_size.y,
        window_mode | c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse {
        panic("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyWindow(screen);

    // Necessary for proper scaling on the Wayland backend in windowed mode
    if (window_mode == c.SDL_WINDOW_RESIZABLE) {
        const pixel_density = c.SDL_GetWindowPixelDensity(screen);
        _ = c.SDL_SetWindowSize(
            screen,
            @intFromFloat(@round(Game.display_size.x / pixel_density)),
            @intFromFloat(@round(Game.display_size.y / pixel_density)),
        );
    }

    // Initialize the graphics context
    const app_version = comptime std.SemanticVersion.parse(build.version) catch unreachable;
    var gx: Gx = .init(allocator, .{
        .app_name = @tagName(build.name),
        .app_version = .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
        },
        .engine_name = @tagName(build.name),
        .engine_version = .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
        },
        .frames_in_flight = 2,
        .timestamp_queries = tracy.enabled,
        .backend = .{
            .instance_extensions = b: {
                var instance_ext_count: u32 = 0;
                const instance_ext_names = c.SDL_Vulkan_GetInstanceExtensions(&instance_ext_count) orelse {
                    return error.SdlVkGetInstanceExtensionsError;
                };
                break :b @ptrCast(instance_ext_names[0..instance_ext_count]);
            },
            .getInstanceProcAddress = @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr()),
            .surface_context = screen,
            .createSurface = &createSurface,
        },
        .debug = args.named.@"gpu-dbg",
    });
    defer {
        gx.waitIdle();
        gx.deinit(allocator);
    }

    // Initialize the renderer
    var renderer: Renderer = .init(allocator, &gx);
    defer {
        gx.waitIdle();
        renderer.deinit(allocator, &gx);
    }

    // Load the assets
    var assets: Assets = .init(allocator);
    defer assets.deinit(allocator);

    const random_seed: u64 = s: {
        var buf: [8]u8 = undefined;
        std.options.cryptoRandomSeed(&buf);
        break :s @bitCast(buf);
    };
    var rng = std.Random.DefaultPrng.init(random_seed);
    const random: std.Random = rng.random();

    var game = try Game.init(allocator, random, &assets, &renderer, &gx);

    game.hot_swap = args.named.@"hot-swap";

    // Create the entities
    var es: Entities = try .init(.{ .gpa = allocator });
    defer es.deinit(allocator);

    var cb = try CmdBuf.init(.{ .name = "cb", .gpa = allocator, .es = &es });
    defer cb.deinit(allocator, &es);

    game.setupScenario(&es, &cb, .deathmatch_2v2);

    // Run the simulation
    var delta_s: f32 = 1.0 / 60.0;
    var timer = try std.time.Timer.start();

    // var warned_memory_usage = false;

    while (true) {
        if (poll(&es, &cb, &game)) {
            std.process.cleanExit();
            return;
        }

        game.timer.update(delta_s);
        update.all(&es, &cb, &game, delta_s);
        render.all(&es, &game, delta_s);

        // TODO(mason): we also want a min frame time so we don't get surprising floating point
        // results if it's too close to zero!
        // Adjust our expectd delta time a little every frame. We cap it at `max_frame_time` to
        // prevent e.g. a slow alt tab from messing things up too much.
        const delta_rwa_bias = 0.05;
        const max_frame_time = 1.0 / 30.0;
        const t: f32 = @floatFromInt(timer.lap());
        const last_delta_s = t / std.time.ns_per_s;
        delta_s = lerp(delta_s, @min(last_delta_s, max_frame_time), delta_rwa_bias);

        // TODO: ...
        // if (fba.end_index >= fba.buffer.len / 4 and !warned_memory_usage) {
        //     std.log.warn(">= 25% of entity memory has been used, consider increasing the size of the fixed buffer allocator", .{});
        //     warned_memory_usage = true;
        // }

        tracy.frameMark(null);
    }
}

fn poll(es: *Entities, cb: *CmdBuf, game: *Game) bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        switch (event.type) {
            c.SDL_EVENT_QUIT => return true,
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => if (game.hot_swap) {
                log.info("hot swap", .{});
                const pipeline = Renderer.initPipeline(
                    game.debug_allocator,
                    game.gx,
                    game.renderer.pipeline_layout,
                );
                game.gx.waitIdle();
                game.renderer.pipeline.deinit(game.gx);
                game.renderer.pipeline = pipeline;
            },
            c.SDL_EVENT_KEY_DOWN => switch (event.key.scancode) {
                c.SDL_SCANCODE_ESCAPE => return true,
                c.SDL_SCANCODE_RETURN => Game.clearInvulnerability(es),
                c.SDL_SCANCODE_1 => {
                    game.setupScenario(es, cb, .deathmatch_2v2);
                },
                c.SDL_SCANCODE_2 => {
                    game.setupScenario(es, cb, .deathmatch_2v2_no_rocks);
                },
                c.SDL_SCANCODE_3 => {
                    game.setupScenario(es, cb, .deathmatch_2v2_one_rock);
                },
                c.SDL_SCANCODE_4 => {
                    game.setupScenario(es, cb, .deathmatch_1v1);
                },
                c.SDL_SCANCODE_5 => {
                    game.setupScenario(es, cb, .deathmatch_1v1_one_rock);
                },
                c.SDL_SCANCODE_6 => {
                    game.setupScenario(es, cb, .royale_4p);
                },
                else => {},
            },
            else => {},
        }
    }
    return false;
}

fn createSurface(
    instance: VkBackend.vk.Instance,
    context: ?*anyopaque,
    allocation_callbacks: ?*const VkBackend.vk.AllocationCallbacks,
) VkBackend.vk.SurfaceKHR {
    const screen: *c.SDL_Window = @ptrCast(@alignCast(context));
    var surface: c.VkSurfaceKHR = undefined;
    if (!c.SDL_Vulkan_CreateSurface(
        screen,
        @ptrFromInt(@intFromEnum(instance)),
        @ptrCast(allocation_callbacks),
        &surface,
    )) {
        return .null_handle;
    }
    return @enumFromInt(@intFromPtr(surface));
}

const FormatSdlLog = struct {
    userdata: ?*anyopaque,
    category: c_int,
    message: [*:0]const u8,
};

fn formatSdlLog(
    data: FormatSdlLog,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    switch (data.category) {
        c.SDL_LOG_CATEGORY_APPLICATION => try writer.writeAll("application: "),
        c.SDL_LOG_CATEGORY_ERROR => try writer.writeAll("error: "),
        c.SDL_LOG_CATEGORY_ASSERT => try writer.writeAll("assert: "),
        c.SDL_LOG_CATEGORY_SYSTEM => try writer.writeAll("system: "),
        c.SDL_LOG_CATEGORY_AUDIO => try writer.writeAll("audio: "),
        c.SDL_LOG_CATEGORY_VIDEO => try writer.writeAll("video: "),
        c.SDL_LOG_CATEGORY_RENDER => try writer.writeAll("render: "),
        c.SDL_LOG_CATEGORY_INPUT => try writer.writeAll("input: "),
        c.SDL_LOG_CATEGORY_TEST => try writer.writeAll("test: "),
        c.SDL_LOG_CATEGORY_GPU => try writer.writeAll("gpu: "),
        c.SDL_LOG_CATEGORY_RESERVED2 => try writer.writeAll("reserved2: "),
        c.SDL_LOG_CATEGORY_RESERVED3 => try writer.writeAll("reserved3: "),
        c.SDL_LOG_CATEGORY_RESERVED4 => try writer.writeAll("reserved4: "),
        c.SDL_LOG_CATEGORY_RESERVED5 => try writer.writeAll("reserved5: "),
        c.SDL_LOG_CATEGORY_RESERVED6 => try writer.writeAll("reserved6: "),
        c.SDL_LOG_CATEGORY_RESERVED7 => try writer.writeAll("reserved7: "),
        c.SDL_LOG_CATEGORY_RESERVED8 => try writer.writeAll("reserved8: "),
        c.SDL_LOG_CATEGORY_RESERVED9 => try writer.writeAll("reserved9: "),
        c.SDL_LOG_CATEGORY_RESERVED10 => try writer.writeAll("reserved10: "),
        else => try writer.print("custom[{}]: ", .{data.category}),
    }

    try writer.print("{s}", .{data.message});
}

fn fmtSDlLog(data: FormatSdlLog) std.fmt.Formatter(formatSdlLog) {
    return .{ .data = data };
}

fn sdlLogCallback(
    userdata: ?*anyopaque,
    category: c_int,
    priority: c.SDL_LogPriority,
    message: [*c]const u8,
) callconv(.C) void {
    const level: std.log.Level = switch (priority) {
        c.SDL_LOG_PRIORITY_INVALID => .err,
        c.SDL_LOG_PRIORITY_TRACE => .debug,
        c.SDL_LOG_PRIORITY_VERBOSE => .debug,
        c.SDL_LOG_PRIORITY_DEBUG => .debug,
        c.SDL_LOG_PRIORITY_INFO => .info,
        c.SDL_LOG_PRIORITY_WARN => .warn,
        c.SDL_LOG_PRIORITY_ERROR => .err,
        c.SDL_LOG_PRIORITY_CRITICAL => .err,
        else => b: {
            log.err("unknown priority {}", .{priority});
            break :b .err;
        },
    };

    const format = "{}";
    const args = .{fmtSDlLog(.{
        .message = message,
        .category = category,
        .userdata = userdata,
    })};
    const scoped = std.log.scoped(.sdl);
    switch (level) {
        .err => scoped.err(format, args),
        .warn => scoped.warn(format, args),
        .info => scoped.info(format, args),
        .debug => scoped.debug(format, args),
    }
}

test {
    _ = @import("symmetric_matrix.zig");
}
