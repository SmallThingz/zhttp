const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zhttp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "zhttp-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhttp", .module = mod },
            },
        }),
    });

    const bench_server_exe = b.addExecutable(.{
        .name = "zhttp-bench-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/zhttp_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhttp", .module = mod },
            },
        }),
    });
    const bench_server_step = b.step("bench-server", "Build the benchmark server");
    bench_server_step.dependOn(&bench_server_exe.step);

    const bench_step = b.step("bench", "Run benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }
    const bench_faf_exe = b.addExecutable(.{
        .name = "zhttp-bench-faf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/run_faf.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const bench_faf_run = b.addRunArtifact(bench_faf_exe);
    bench_faf_run.addPrefixedArtifactArg("--bench-bin=", bench_exe);
    if (b.args) |args| {
        bench_faf_run.addArgs(args);
    }
    bench_faf_run.step.dependOn(&bench_cmd.step);
    bench_step.dependOn(&bench_faf_run.step);

    const examples_step = b.step("examples", "Build all examples");
    const examples_check_step = b.step("examples-check", "Run all examples with --smoke");

    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "basic_server", .path = "examples/basic_server.zig" },
        .{ .name = "middleware", .path = "examples/middleware.zig" },
        .{ .name = "builtin_middlewares", .path = "examples/builtin_middlewares.zig" },
        .{ .name = "echo_body", .path = "examples/echo_body.zig" },
        .{ .name = "fast_plaintext", .path = "examples/fast_plaintext.zig" },
    };

    inline for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = b.fmt("zhttp-example-{s}", .{ex.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zhttp", .module = mod },
                },
            }),
        });
        examples_step.dependOn(&exe.step);

        const run = b.addRunArtifact(exe);
        run.addArg("--smoke");
        examples_check_step.dependOn(&run.step);
    }
}
