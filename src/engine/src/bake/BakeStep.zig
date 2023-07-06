const Self = @This();

const std = @import("std");
const Step = std.Build.Step;
const FileSource = std.Build.FileSource;

ctx: *anyopaque,
impl: *const fn (ctx: *anyopaque, asset: Paths) anyerror!Baked,

/// It is safe to assume the strings will not be freed prior to build graph execution.
pub const Paths = struct {
    /// The path to the asset. Will not be freed before build graph execution.
    data: []const u8,
    /// The path to the bake config. Will not be freed before build graph execution.
    config: []const u8,
    /// The default install path for this asset.
    install: []const u8,
};

pub const Baked = struct {
    // The baked file.
    file_source: FileSource,
    // The path at which to install the asset. If null uses the default.
    install_path: ?[]const u8 = null,
};

pub fn create(
    ctx: anytype,
    comptime impl: *const fn (ctx: @TypeOf(ctx), asset: Paths) anyerror!Baked,
) Self {
    if (@typeInfo(@TypeOf(ctx)) != .Pointer)
        @compileError("expected pointer");
    return .{
        .ctx = @constCast(@ptrCast(@alignCast(ctx))),
        .impl = struct {
            fn wrapped(untyped: *anyopaque, asset: Paths) anyerror!Baked {
                const typed: @TypeOf(ctx) = @ptrCast(@alignCast(untyped));
                return impl(typed, asset);
            }
        }.wrapped,
    };
}

/// Adds a run artifact, gives it an input arg, and names the process `$NAME (input_path)`.
pub fn addRunArtifactWithInput(exe: *Step.Compile, input_path: []const u8) !*Step.Run {
    const process = exe.step.owner.addRunArtifact(exe);
    const name = try std.fmt.allocPrint(exe.step.owner.allocator, "{s} ({s})", .{
        process.step.name,
        input_path,
    });
    process.setName(name);

    const write_step = exe.step.owner.addWriteFiles();
    const file_source = write_step.addCopyFile(FileSource.relative(input_path), input_path);
    process.addFileSourceArg(file_source);

    return process;
}

pub const default = Self.create(&{}, addCopy);

fn addCopy(_: *const void, paths: Paths) anyerror!Baked {
    return .{
        .file_source = FileSource.relative(paths.data),
    };
}

fn add(self: *const Self, paths: Paths) !Baked {
    return self.impl(self.ctx, paths);
}
