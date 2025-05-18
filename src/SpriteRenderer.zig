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

pub const max_instances = 16384;

storage_layout: StorageLayout,
storage: UploadBuf(.{ .storage = true }),
instances: Writer,
first_instance: u32,
instance_count: u32,

pub const Ubo = struct {
    const Scene = extern struct {
        view_from_world: Mat2x3 = .identity,
    };
    const Instance = extern struct {
        world_from_model: Mat2x3,
        texture_index: u32,
    };
};

pub const StorageLayout = BufferLayout(.{
    .kind = .{ .storage = true },
    .frame = &.{
        .{
            .name = "scene",
            .size = @sizeOf(Ubo.Scene),
            .alignment = @alignOf(Ubo.Scene),
        },
        .{
            .name = "instances",
            .size = @sizeOf(Ubo.Instance) * max_instances,
            .alignment = @alignOf(Ubo.Instance),
        },
    },
});

pub const Options = struct {
    storage_layout: StorageLayout,
    storage: UploadBuf(.{ .storage = true }),
};

pub fn init(options: Options) @This() {
    return .{
        .storage_layout = options.storage_layout,
        .storage = options.storage,
        .instances = undefined,
        .first_instance = undefined,
        .instance_count = undefined,
    };
}

pub fn begin(self: *@This(), gx: *Gx, scene: Ubo.Scene) void {
    assert(gx.in_frame);

    const frame = self.storage_layout.frame(gx.frame);

    var scene_writer = frame.scene.writer(self.storage);
    scene_writer.writeStruct(scene) catch |err| @panic(@errorName(err));

    self.instances = frame.instances.writer(self.storage);
    self.first_instance = 0;
    self.instance_count = 0;
}

pub fn draw(self: *@This(), options: Ubo.Instance) void {
    if (self.instance_count > max_instances) @panic("sprite instance_count oob");
    self.instances.writeStruct(options) catch |err| @panic(@errorName(err));
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
