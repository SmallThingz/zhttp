const std = @import("std");

/// Configures build steps for this package.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zhttp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const zws_dep = b.lazyDependency("zwebsocket", .{
        .target = target,
        .optimize = optimize,
    });
    const zstd_dep = b.lazyDependency("zcompress", .{
        .target = target,
        .optimize = optimize,
        .static_libc = false,
    });
    const brotli_dep = b.lazyDependency("libbrotli", .{
        .target = target,
        .optimize = optimize,
        .static_libc = false,
    });

    const zstd_mod = if (zstd_dep) |dep|
        dep.module("zcompress")
    else
        @panic("missing 'zcompress' dependency; run `zig fetch --save ../zcompress`");
    const brotli_mod = if (brotli_dep) |dep|
        dep.module("libbrotli")
    else
        @panic("missing 'libbrotli' dependency; run `zig fetch --save ../libbrotli.zig`");
    mod.addImport("zcompress", zstd_mod);
    mod.addImport("libbrotli", brotli_mod);

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_root.zig"),
            .target = target,
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    mod_tests.root_module.addImport("zcompress", zstd_mod);
    mod_tests.root_module.addImport("libbrotli", brotli_mod);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.addArgs(&.{ "--jobs", "1", "--exclude-filter", "server.test.", "--exclude-filter", "loopback listen preflight" });
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

    const origin_bench_exe = b.addExecutable(.{
        .name = "zhttp-bench-origin-match",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/origin_match.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    origin_bench_exe.root_module.addImport("zhttp", mod);
    const origin_bench_run = b.addRunArtifact(origin_bench_exe);
    if (b.args) |args| {
        origin_bench_run.addArgs(args);
    }
    const origin_bench_step = b.step("bench-origin", "Benchmark origin decision tree against a hash map baseline");
    origin_bench_step.dependOn(&origin_bench_run.step);

    const bench_step = b.step("bench", "Run benchmarks");
    const bench_zhttp_exe = b.addExecutable(.{
        .name = "zhttp-bench-zhttp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/run_zhttp_external.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const bench_zhttp_run = b.addRunArtifact(bench_zhttp_exe);
    if (b.args) |args| {
        bench_zhttp_run.addArgs(args);
    }
    bench_step.dependOn(&bench_zhttp_run.step);
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
    bench_faf_run.step.dependOn(&bench_exe.step);
    bench_step.dependOn(&bench_faf_run.step);

    const examples_step = b.step("examples", "Build all examples");
    const examples_check_step = b.step("examples-check", "Run all examples with --smoke");

    const examples = [_]struct { name: []const u8, path: []const u8, uses_zws: bool }{
        .{ .name = "basic_server", .path = "examples/basic_server.zig", .uses_zws = false },
        .{ .name = "middleware", .path = "examples/middleware.zig", .uses_zws = false },
        .{ .name = "builtin_middlewares", .path = "examples/builtin_middlewares.zig", .uses_zws = false },
        .{ .name = "echo_body", .path = "examples/echo_body.zig", .uses_zws = false },
        .{ .name = "fast_plaintext", .path = "examples/fast_plaintext.zig", .uses_zws = false },
        .{ .name = "ws_manual_upgrade", .path = "examples/ws_manual_upgrade.zig", .uses_zws = true },
    };

    inline for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = b.fmt("zhttp-example-{s}", .{ex.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("zhttp", mod);
        if (ex.uses_zws) {
            const dep = zws_dep orelse @panic("missing 'zwebsocket' dependency; run `zig fetch --save <zws-url>`");
            exe.root_module.addImport("zwebsocket", dep.module("zwebsocket"));
        }
        examples_step.dependOn(&exe.step);

        const run = b.addRunArtifact(exe);
        run.addArg("--smoke");
        examples_check_step.dependOn(&run.step);
    }
}
