const std = @import("std");
const c = @import("c.zig").c;
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

const Logger = logger.Logger(.{ .history = .none });
pub const std_options: std.Options = .{
    .logFn = Logger.logFn,
    .log_level = .debug,
};

pub const gpu_options: gpu.Options = .{
    .Backend = VkBackend,
};

pub const Surface = enum {
    auto,
    hdr10,
    @"linear-srgb",
    @"nonlinear-srgb",
    @"linear-srgb-extended",
    @"nonlinear-srgb-extended",
};

const command: Command = .{
    .name = @tagName(build.name),
    .named_args = &.{
        NamedArg.init(Gx.Validation, .{
            .long = "gpu-validation",
            .default = .{ .value = .default },
        }),
        // Just shaders for now
        NamedArg.init(bool, .{
            .long = "hot-swap",
            .default = .{ .value = if (builtin.mode == .Debug) true else false },
        }),
        NamedArg.init(bool, .{
            .long = "prefer-integrated",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "safe-mode",
            .default = .{ .value = false },
        }),
        NamedArg.init(std.log.Level, .{
            .long = "log-level",
            .default = .{ .value = .info },
        }),
        NamedArg.init(bool, .{
            .long = "moving-avg-blur",
            .default = .{ .value = false },
        }),
        NamedArg.init(Surface, .{
            .long = "surface",
            .default = .{ .value = .auto },
        }),
        NamedArg.init(bool, .{
            .long = "latency-test",
            .default = .{ .value = false },
        }),
        NamedArg.init(bool, .{
            .long = "fullscreen",
            .default = .{ .value = false },
        }),
    },
};

fn handleResize(userdata: ?*anyopaque, event: [*c]c.SDL_Event) callconv(.c) bool {
    const game: *Game = @alignCast(@ptrCast(userdata));
    switch (event.*.type) {
        c.SDL_EVENT_WINDOW_EXPOSED => {
            render.all(game, 0);
            return false;
        },
        c.SDL_EVENT_WINDOW_RESIZED => {
            game.window_extent = .{
                .width = @intCast(event.*.window.data1),
                .height = @intCast(event.*.window.data2),
            };
            game.resize_timer.reset();
            return false;
        },
        else => return true,
    }
}

fn getRefreshRate(window: *c.SDL_Window) f32 {
    const display = c.SDL_GetDisplayForWindow(window);
    if (display == 0) return 0.0;
    const display_mode = c.SDL_GetCurrentDisplayMode(display) orelse return 0.0;
    return display_mode[0].refresh_rate;
}

pub fn main() !void {
    c.SDL_SetLogPriorities(c.SDL_LOG_PRIORITY_TRACE);
    c.SDL_SetLogOutputFunction(&sdlLogCallback, null);
    if (!c.SDL_SetAppMetadata(@tagName(build.name), build.version, null)) {
        panic("SDL_SetAppMetadata failed: {s}\n", .{c.SDL_GetError()});
    }

    // Allocator setup
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    defer if (gpa.deinit() != .ok) @panic("leak detected");
    var tracy_allocator: tracy.Allocator = .{
        .pool_name = "gpa",
        .parent = gpa.allocator(),
    };
    const allocator = tracy_allocator.allocator();

    const args = try command.parse(allocator);
    defer command.parseFree(args);
    Logger.runtime_level = args.named.@"log-level";

    // Init SDL
    if (!c.SDL_SetHintWithPriority(
        c.SDL_HINT_NO_SIGNAL_HANDLERS,
        "1",
        c.SDL_HINT_OVERRIDE,
    )) {
        log.err("SDL_SetHintWithPriority failed: {s}", .{c.SDL_GetError()});
    }
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMEPAD | c.SDL_INIT_AUDIO)) {
        panic("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    std.log.scoped(.sdl).info("video driver: {s}", .{c.SDL_GetCurrentVideoDriver() orelse @as([*c]const u8, "null")});
    std.log.scoped(.sdl).info("audio driver: {s}", .{c.SDL_GetCurrentAudioDriver() orelse @as([*c]const u8, "null")});

    const window_mode = if (args.named.fullscreen)
        c.SDL_WINDOW_FULLSCREEN
    else
        c.SDL_WINDOW_RESIZABLE;

    const screen = c.SDL_CreateWindow(
        @tagName(build.name),
        Game.display_size.x,
        Game.display_size.y,
        window_mode | c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse {
        panic("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyWindow(screen);

    const init_window_extent: gpu.Extent2D = b: {
        var width: c_int = 0;
        var height: c_int = 0;
        if (!c.SDL_GetWindowSizeInPixels(screen, &width, &height)) {
            std.debug.panic("SDL_GetWindowSizeInPixels failed: {s}\n", .{c.SDL_GetError()});
        }
        break :b .{ .width = @intCast(width), .height = @intCast(height) };
    };

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
        .surface_format = switch (args.named.surface) {
            // We can't just list them all here, on some systems it will incorrectly show HDR
            // formats as available even when HDR is off, leading to incorrect visuals...
            .auto => &.{Renderer.Surface.linear_srgb.query()},
            .hdr10 => &.{Renderer.Surface.hdr10.query()},
            .@"linear-srgb" => &.{Renderer.Surface.linear_srgb.query()},
            .@"nonlinear-srgb" => &.{Renderer.Surface.nonlinear_srgb.query()},
            .@"nonlinear-srgb-extended" => &.{Renderer.Surface.nonlinear_srgb_extended.query()},
            .@"linear-srgb-extended" => &.{Renderer.Surface.linear_srgb_extended.query()},
        },
        .surface_extent = init_window_extent,
        .validation = args.named.@"gpu-validation",
        .device_type_ranks = b: {
            var ranks = Gx.Options.default_device_type_ranks;
            if (args.named.@"prefer-integrated") {
                ranks.getPtr(.integrated).* = std.math.maxInt(u8);
            }
            break :b ranks;
        },
        .safe_mode = args.named.@"safe-mode",
        .window = @enumFromInt(@intFromPtr(switch (builtin.os.tag) {
            .windows => c.SDL_GetPointerProperty(
                c.SDL_GetWindowProperties(screen),
                c.SDL_PROP_WINDOW_WIN32_HWND_POINTER,
                null,
            ),
            .linux => @as(?*anyopaque, @ptrFromInt(@as(usize, @bitCast(c.SDL_GetNumberProperty(
                c.SDL_GetWindowProperties(screen),
                c.SDL_PROP_WINDOW_X11_WINDOW_NUMBER,
                0,
            ))))) orelse c.SDL_GetPointerProperty(
                c.SDL_GetWindowProperties(screen),
                c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER,
                null,
            ),
            else => comptime unreachable,
        })),
        .arena_capacity_log2 = 32,
    });
    defer {
        gx.waitIdle();
        gx.deinit(allocator);
    }

    // Initialize the renderer
    var renderer: Renderer = .init(allocator, &gx, init_window_extent);
    renderer.moving_avg_blur = args.named.@"moving-avg-blur";
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

    // Create the entities
    var es: Entities = try .init(.{ .gpa = allocator });
    defer es.deinit(allocator);

    var game = try Game.init(
        allocator,
        random,
        &es,
        &assets,
        &renderer,
        &gx,
        init_window_extent,
        if (args.named.@"latency-test") .a else .off,
        screen,
    );

    game.hot_swap = args.named.@"hot-swap";

    var cb = try CmdBuf.init(.{ .name = "cb", .gpa = allocator, .es = &es });
    defer cb.deinit(allocator, &es);

    game.setupScenario(&es, &cb, .deathmatch_2v2);

    if (builtin.target.os.tag == .windows) {
        // Windows blocks the whole app during resizes, but you can still get the resize events
        // from the event filter to prevent it from just rendering the last frame stretched. X11 and
        // Wayland don't require this code path, and in fact doing it anyway is problematic (you end
        // up queuing presents faster than you can render them.)
        c.SDL_SetEventFilter(&handleResize, &game);
    }

    // Run the simulation
    var pacer: gpu.ext.FramePacer = .init(getRefreshRate(screen));
    while (true) {
        {
            const zone = Zone.begin(.{ .name = "poll input", .src = @src() });
            defer zone.end();
            if (poll(&es, &cb, &game, &pacer)) {
                tracy.cleanExit();
                return;
            }
        }

        update.all(&cb, &game, pacer.smoothed_delta_s);
        render.all(&game, pacer.smoothed_delta_s);

        tracy.frameMark(null);

        {
            const sleep_ns = pacer.update(game.gx.slop_ns);
            const zone = Zone.begin(.{
                .name = "frame pacer sleep",
                .src = @src(),
                .color = gpu_options.blocking_zone_color,
            });
            defer zone.end();
            if (game.latency_test != .b) c.SDL_DelayPrecise(sleep_ns);
        }

        game.timer.update(pacer.smoothed_delta_s);
    }
}

fn poll(es: *Entities, cb: *CmdBuf, game: *Game, pacer: *gpu.ext.FramePacer) bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        if (!handleResize(game, &event)) continue;
        switch (event.type) {
            c.SDL_EVENT_QUIT => return true,
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => if (game.hot_swap) {
                log.info("hot swap", .{});
                const pipelines: Renderer.Pipelines = .init(
                    game.debug_allocator,
                    game.gx,
                    game.renderer.pipeline_layout,
                );
                game.gx.waitIdle();
                game.renderer.pipelines.deinit(game.gx);
                game.renderer.pipelines = pipelines;
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
                c.SDL_SCANCODE_A => if (game.latency_test != .off) {
                    game.latency_test = .a;
                    game.gx.setLowLatency(true);
                },
                c.SDL_SCANCODE_B => if (game.latency_test != .off) {
                    game.latency_test = .b;
                    game.gx.setLowLatency(false);
                },
                else => {},
            },
            c.SDL_EVENT_DISPLAY_CURRENT_MODE_CHANGED => {
                log.debug("SDL_EVENT_DISPLAY_CURRENT_MODE_CHANGED", .{});
                pacer.refresh_rate_hz = getRefreshRate(game.screen);
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
    var surface: c.VkSurfaceKHR = null;
    if (!c.SDL_Vulkan_CreateSurface(
        screen,
        @ptrFromInt(@intFromEnum(instance)),
        @ptrCast(allocation_callbacks),
        &surface,
    )) {
        log.err("SDL_SetHintWithPriority failed: {s}", .{c.SDL_GetError()});
    }
    return @enumFromInt(@intFromPtr(surface));
}

const FormatSdlLog = struct {
    category: c_int,
    message: [*:0]const u8,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.category) {
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
            else => try writer.print("custom[{}]: ", .{self.category}),
        }

        try writer.print("{s}", .{self.message});
    }
};

fn sdlLogCallback(
    userdata: ?*anyopaque,
    category: c_int,
    priority: c.SDL_LogPriority,
    message: [*c]const u8,
) callconv(.c) void {
    _ = userdata;
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

    const msg: FormatSdlLog = .{
        .message = message,
        .category = category,
    };
    const scoped = std.log.scoped(.sdl);
    switch (level) {
        .err => scoped.err("{f}", .{msg}),
        .warn => scoped.warn("{f}", .{msg}),
        .info => scoped.info("{f}", .{msg}),
        .debug => scoped.debug("{f}", .{msg}),
    }
}

test {
    _ = @import("symmetric_matrix.zig");
}
