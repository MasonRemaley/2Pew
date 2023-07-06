const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const Module = Build.Module;

const self_path = "projects/engine";

pub const Options = struct {
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    test_step: *Step,
    bench_step: *Step,
};

pub fn build(b: *Build, options: Options) !*Module {
    const module = b.createModule(.{
        .source_file = .{ .path = self_path ++ "/src/engine.zig" },
    });

    const engine_tests = b.addTest(.{
        .root_source_file = .{ .path = self_path ++ "/src/engine.zig" },
        .target = options.target,
        .optimize = options.optimize,
    });
    const run_engine_tests = b.addRunArtifact(engine_tests);
    options.test_step.dependOn(&run_engine_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_source_file = .{ .path = self_path ++ "/bench.zig" },
        .target = options.target,
        .optimize = options.optimize,
    });
    bench_exe.override_dest_dir = .prefix;
    const bench_cmd = b.addRunArtifact(bench_exe);
    options.bench_step.dependOn(&bench_cmd.step);

    return module;
}
