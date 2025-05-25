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
    },
};

pub fn main() !void {
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
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMEPAD)) {
        panic("SDL_Init failed: {?s}\n", .{c.SDL_GetError()});
    }
    defer c.SDL_Quit();

    const window_mode = switch (builtin.mode) {
        .Debug => c.SDL_WINDOW_RESIZABLE,
        else => c.SDL_WINDOW_FULLSCREEN,
    };

    const screen = c.SDL_CreateWindow(
        @tagName(build.name),
        Game.display_size.x,
        Game.display_size.y,
        window_mode | c.SDL_WINDOW_VULKAN,
    ) orelse {
        panic("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
    };
    defer c.SDL_DestroyWindow(screen);

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
                log.err(":: {s}", .{instance_ext_names[0..instance_ext_count]});
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

    var game = try Game.init(allocator, &assets, &renderer, &gx);

    // Create the entities
    var es: Entities = try .init(.{ .gpa = allocator });
    defer es.deinit(allocator);

    var cb = try CmdBuf.init(.{ .name = "cb", .gpa = allocator, .es = &es });
    defer cb.deinit(allocator, &es);

    game.setupScenario(&es, &cb, .deathmatch_2v2);

    // Run the simulation
    var delta_s: f32 = 1.0 / 60.0;
    var timer = try std.time.Timer.start();

    // We can use `fx_loop_s` as a time parameter for looping effects without needing extra
    // state everywhere. We loop it at 1000 so that we don't lose precision as the game runs, 1000
    // was chosen so that so long as our effect frequency per second can be any number with three or
    // less digits after the decimal and still loop seemlessly when we reset back to zero.
    var fx_loop_s: f32 = 0.0;
    const max_fx_loop_s: f32 = 1000.0;
    // var warned_memory_usage = false;

    while (true) {
        if (poll(&es, &cb, &game)) {
            std.process.cleanExit();
            return;
        }
        update.all(&es, &cb, &game, delta_s);
        render.all(&es, &game, delta_s, fx_loop_s);

        // TODO(mason): we also want a min frame time so we don't get surprising floating point
        // results if it's too close to zero!
        // Adjust our expectd delta time a little every frame. We cap it at `max_frame_time` to
        // prevent e.g. a slow alt tab from messing things up too much.
        const delta_rwa_bias = 0.05;
        const max_frame_time = 1.0 / 30.0;
        const t: f32 = @floatFromInt(timer.lap());
        const last_delta_s = t / std.time.ns_per_s;
        delta_s = lerp(delta_s, @min(last_delta_s, max_frame_time), delta_rwa_bias);
        fx_loop_s = @mod(fx_loop_s + delta_s, max_fx_loop_s);

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

test {
    _ = @import("symmetric_matrix.zig");
}
