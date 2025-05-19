const std = @import("std");
const gpu = @import("gpu");
const geom = @import("zcs").ext.geom;

const BufferLayout = @import("buffer_layout.zig").BufferLayout;

const UploadBuf = gpu.UploadBuf;
const Writer = gpu.Writer;
const Gx = gpu.Gx;
const CmdBuf = gpu.CmdBuf;
const Mat2x3 = geom.Mat2x3;

const assert = std.debug.assert;

scene: [gpu.global_options.max_frames_in_flight]Writer,
instances: [gpu.global_options.max_frames_in_flight]Writer,
first_instance: u32 = 0,
instance_count: u32 = 0,

pub const Ubo = struct {
    pub const Scene = extern struct {
        view_from_world: Mat2x3 = .identity,
    };
    pub const Instance = extern struct {
        world_from_model: Mat2x3,
        texture_index: u32,
    };
};

pub const Options = struct {
    scene: [gpu.global_options.max_frames_in_flight]Writer,
    instances: [gpu.global_options.max_frames_in_flight]Writer,
};

pub fn init(options: Options) @This() {
    var result: @This() = .{
        .scene = options.scene,
        .instances = options.instances,
        .first_instance = undefined,
        .instance_count = undefined,
    };
    for (&result.scene, &result.instances) |*scene_writer, *instance_writer| {
        scene_writer.trim();
        instance_writer.trim();
    }
    return result;
}

pub fn begin(self: *@This(), gx: *Gx, scene: Ubo.Scene) void {
    assert(gx.in_frame);

    self.scene[gx.frame].reset();
    self.instances[gx.frame].reset();

    self.scene[gx.frame].writeStruct(scene) catch |err| @panic(@errorName(err));

    self.first_instance = 0;
    self.instance_count = 0;
}

pub fn draw(self: *@This(), gx: *Gx, options: Ubo.Instance) void {
    self.instances[gx.frame].writeStruct(options) catch |err| @panic(@errorName(err));
    self.instance_count += 1;
}

pub fn submit(self: *@This(), gx: *Gx, cb: CmdBuf) void {
    if (self.instance_count > 0) {
        cb.draw(gx, .{
            .vertex_count = 4,
            .instance_count = self.instance_count,
            .first_vertex = self.first_instance,
            .first_instance = 0,
        });
        self.first_instance += self.instance_count;
    }
}
