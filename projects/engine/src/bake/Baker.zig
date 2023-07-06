const std = @import("std");
const Self = @This();
const Step = std.Build.Step;
const AssetType = @import("AssetType.zig");
const assert = std.debug.assert;

owner: *std.Build,
data_path: []const u8,
install_root: []const u8,
install_prefix: []const u8,
install_dir: []const u8,
write_output: *Step.WriteFile,

pub const Options = struct {
    data_path: []const u8,
    install_root: []const u8,
    install_prefix: []const u8,
};

pub fn create(owner: *std.Build, options: Options) !Self {
    assert(options.install_prefix.len > 0);
    return .{
        .owner = owner,
        .data_path = options.data_path,
        .install_root = options.install_root,
        .install_prefix = options.install_prefix,
        .install_dir = try std.fs.path.join(owner.allocator, &.{ options.install_root, options.install_prefix }),
        .write_output = owner.addWriteFiles(),
    };
}

// NOTE: this could be implemented as an option for `addInstallFileWithDir`
pub fn prune(self: *const Self) void {
    self.pruneChecked() catch |err| std.debug.panic("prune failed: {}", .{err});
}

fn pruneChecked(self: *const Self) !void {
    // Create a hashmap of all installed files
    var installed_files = std.StringArrayHashMapUnmanaged(void){};
    defer installed_files.deinit(self.owner.allocator);
    for (self.owner.installed_files.items) |file| {
        if (file.dir == .custom and std.mem.eql(u8, file.dir.custom, self.install_dir)) {
            try installed_files.put(self.owner.allocator, file.path, {});
        }
    }

    // Remove any files from the subdirectory that were not installed this time
    const install_path = try std.fs.path.join(self.owner.allocator, &.{
        self.owner.install_prefix,
        self.install_dir,
    });
    defer self.owner.allocator.free(install_path);
    var old_files = std.fs.openIterableDirAbsolute(install_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer old_files.close();
    var walker = try old_files.walk(self.owner.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            if (!installed_files.contains(entry.path)) {
                try entry.dir.deleteFile(entry.basename);
            }
        }
    }
}

pub fn addAssetType(self: *Self) AssetType {
    return .{
        .bake_assets = self,
        .assets = .{},
    };
}
