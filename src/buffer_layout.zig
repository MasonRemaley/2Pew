const std = @import("std");
const gpu = @import("gpu");
const Gx = gpu.Gx;
const BufHandle = gpu.BufHandle;
const UploadBuf = gpu.UploadBuf;
const BufKind = gpu.BufKind;
const log = std.log.scoped(.buffer_layout);
const Writer = gpu.Writer;

pub const Options = struct {
    const Partition = struct {
        name: [:0]const u8,
        /// The size of the data. The buffer size may be increased beyond this to satisfy alignment
        /// requirements.
        size: u64,
        /// The alignment of the underlying data. The buffer alignment may be increased beyond this
        /// to satisfy alignment requirements for the given buffer kind.
        alignment: u16,
    };

    kind: BufKind,
    global: []const Partition = &.{},
    frame: []const Partition = &.{},
};

pub fn BufferLayout(options: Options) type {
    return struct {
        const Global = BufferPartitions(options.global, options.kind);
        const Frame = BufferPartitions(options.frame, options.kind);

        comptime kind: BufKind = options.kind,
        global: Global,
        frame_relative: Frame,
        frame_size: u64,
        buffer_size: u64,

        pub fn init(gx: *const Gx) @This() {
            const global_size, const global = initSection(
                Global,
                gx,
                0,
            );
            const frame_size, const frame_relative = initSection(
                Frame,
                gx,
                global_size,
            );
            const buffer_size = global_size + frame_size * gpu.global_options.max_frames_in_flight;
            return .{
                .global = global,
                .frame_relative = frame_relative,
                .frame_size = frame_size,
                .buffer_size = buffer_size,
            };
        }

        fn initSection(
            T: type,
            gx: *const Gx,
            start_offset: u64,
        ) struct { u64, T } {
            var section: T = undefined;
            var hardware_alignment: u16 = 1;
            if (options.kind.uniform) {
                hardware_alignment = @max(hardware_alignment, gx.device.uniform_buf_offset_alignment);
            }
            if (options.kind.storage) {
                hardware_alignment = @max(hardware_alignment, gx.device.storage_buf_offset_alignment);
            }
            // The alignment requirements for these doesn't appear to be documented. It may be
            // the case that only the offsets into them need to be properly aligned. Regardless,
            // I've set the minimum alignment to the std140 alignment of the underlying types
            // just in case.
            if (options.kind.indirect) {
                hardware_alignment = @max(hardware_alignment, 4);
            }
            if (options.kind.index) {
                hardware_alignment = @max(hardware_alignment, 2);
            }
            var offset: u64 = 0;
            inline for (@typeInfo(@TypeOf(section)).@"struct".fields) |field| {
                const partition = &@field(section, field.name);
                const alignment = std.mem.alignForward(u16, partition.alignment, hardware_alignment);
                partition.* = .{ .offset = start_offset + offset };
                offset = std.mem.alignForward(u64, offset + partition.size, alignment);
            }
            return .{ offset, section };
        }

        pub fn frame(self: @This(), frame_index: u8) Frame {
            const frame_offset = self.frame_size * frame_index;
            var frame_offsets = self.frame_relative;
            inline for (@typeInfo(Frame).@"struct".fields) |field| {
                @field(frame_offsets, field.name).offset += frame_offset;
            }
            return frame_offsets;
        }

        pub fn Frames(partition: []const u8) type {
            return [gpu.global_options.max_frames_in_flight]@FieldType(Frame, partition);
        }

        pub fn frames(self: @This(), comptime partition: []const u8) Frames(partition) {
            var result: Frames(partition) = undefined;
            for (&result, 0..) |*result_frame, frame_index| {
                result_frame.* = @field(self.frame(@intCast(frame_index)), partition);
            }
            return result;
        }

        pub fn frameWriters(
            self: @This(),
            handle: UploadBuf(options.kind),
            comptime partition: []const u8,
        ) [gpu.global_options.max_frames_in_flight]Writer {
            const field_frames = self.frames(partition);
            var result: [gpu.global_options.max_frames_in_flight]Writer = undefined;
            for (&result, field_frames) |*writer, field_frame| {
                writer.* = field_frame.writer(handle);
            }
            return result;
        }
    };
}

fn BufferPartitions(partitions: []const Options.Partition, kind: BufKind) type {
    var fields: [partitions.len]std.builtin.Type.StructField = undefined;
    for (&fields, partitions) |*field, partition| {
        const Partition = struct {
            comptime size: u64 = partition.size,
            comptime alignment: u16 = partition.alignment,
            offset: u64,

            pub fn view(self: @This(), handle: BufHandle(kind)) BufHandle(kind).View {
                return .{
                    .handle = handle,
                    .offset = self.offset,
                    .size = self.size,
                };
            }

            pub fn writer(self: @This(), handle: UploadBuf(kind)) Writer {
                return handle.writer(.{
                    .offset = self.offset,
                    .size = self.size,
                });
            }
        };
        field.* = .{
            .name = partition.name,
            .type = Partition,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Partition),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}
