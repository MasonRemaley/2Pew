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

pub fn Instancer(InstanceUbo: type) type {
    return struct {
        instances: [gpu.global_options.max_frames_in_flight]Writer,
        first_instance: u32 = 0,
        instance_count: u32 = 0,

        pub fn init(instances: [gpu.global_options.max_frames_in_flight]Writer) @This() {
            for (instances) |instance| {
                assert(instance.pos == 0);
                assert(instance.size % @sizeOf(InstanceUbo) == 0);
                assert(@intFromPtr(instance.write_only_memory) % @alignOf(InstanceUbo) == 0);
            }
            return .{
                .instances = instances,
                .first_instance = undefined,
                .instance_count = undefined,
            };
        }

        pub fn begin(self: *@This(), gx: *Gx) void {
            assert(gx.in_frame);
            self.instances[gx.frame].reset();
            self.first_instance = 0;
            self.instance_count = 0;
        }

        pub fn draw(self: *@This(), gx: *Gx, instance: InstanceUbo) void {
            self.instances[gx.frame].writeStruct(instance) catch |err| @panic(@errorName(err));
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
    };
}
