const gpu = @import("gpu");

const Gx = gpu.Gx;
const CmdBuf = gpu.CmdBuf;
const VolatileWriter = gpu.VolatileWriter;
const UploadBuf = gpu.UploadBuf;
const DebugName = gpu.DebugName;
const Image = gpu.Image;

cb: CmdBuf.Optional,
staging: gpu.UploadBuf(.{ .transfer_src = true }),
writer: VolatileWriter,

pub const Options = struct {
    name: gpu.DebugName,
    bytes: u64,
};

pub fn init(gx: *Gx, options: Options) @This() {
    const staging: gpu.UploadBuf(.{ .transfer_src = true }) = .init(gx, .{
        .name = options.name,
        .size = options.bytes,
        .prefer_device_local = false,
    });

    const writer = staging.writer(.{});

    return .{
        .cb = .none,
        .staging = staging,
        .writer = writer,
    };
}

pub fn deinit(self: *@This(), gx: *Gx) void {
    self.staging.deinit(gx);
    self.* = undefined;
}

pub fn beginWrite(
    self: *@This(),
    gx: *Gx,
    options: Image(.color).InitOptions,
) gpu.Image(.color) {
    const cb = self.cb.unwrap() orelse b: {
        const cb: CmdBuf = .init(gx, .{
            .name = "Color Image Upload",
            .src = @src(),
        });
        self.cb = cb.asOptional();
        break :b cb;
    };

    const image: gpu.Image(.color) = .init(gx, options);

    cb.barriers(gx, .{ .image = &.{
        .undefinedToTransferDst(.{
            .handle = image.handle,
            .range = .first,
            .aspect = .{ .color = true },
        }),
    } });

    cb.uploadImage(gx, .{
        .dst = image.handle,
        .src = self.staging.handle,
        .base_mip_level = 0,
        .mip_levels = 1,
        .regions = &.{
            .init(.{
                .aspect = .{ .color = true },
                .image_extent = options.image.extent,
                .buffer_offset = self.writer.pos,
            }),
        },
    });

    cb.barriers(gx, .{ .image = &.{.transferDstToReadOnly(.{
        .handle = image.handle,
        .range = .first,
        .dst_stage = .{ .fragment_shader = true },
        .aspect = .{ .color = true },
    })} });

    return image;
}

pub fn submit(self: *@This(), gx: *Gx) void {
    if (self.cb.unwrap()) |cb| {
        cb.submit(gx);
        self.cb = .none;
    }
}
