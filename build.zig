const std = @import("std");

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

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_root.zig"),
            .target = target,
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.addArgs(&.{ "--jobs", "1", "--exclude-filter", "server.test.", "--exclude-filter", "loopback listen preflight" });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    if (zws_dep) |dep| {
        const ws_support_mod = b.createModule(.{
            .root_source_file = b.path("websocket_support.zig"),
            .target = target,
            .optimize = optimize,
        });
        ws_support_mod.addImport("zhttp", mod);
        ws_support_mod.addImport("zwebsocket", dep.module("zwebsocket"));

        const ws_tests_mod = b.createModule(.{
            .root_source_file = b.path("websocket_test.zig"),
            .target = target,
        });
        ws_tests_mod.addImport("zhttp", mod);
        ws_tests_mod.addImport("zwebsocket", dep.module("zwebsocket"));
        ws_tests_mod.addImport("zhttp_ws_support", ws_support_mod);

        const ws_tests = b.addTest(.{
            .root_module = ws_tests_mod,
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        const run_ws_tests = b.addRunArtifact(ws_tests);
        run_ws_tests.addArgs(&.{ "--jobs", "1" });
        test_step.dependOn(&run_ws_tests.step);
    }

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

    if (zws_dep) |dep| {
        const ws_support_mod = b.createModule(.{
            .root_source_file = b.path("websocket_support.zig"),
            .target = target,
            .optimize = optimize,
        });
        ws_support_mod.addImport("zhttp", mod);
        ws_support_mod.addImport("zwebsocket", dep.module("zwebsocket"));

        const stress_mod = b.createModule(.{
            .root_source_file = b.path("benchmark/websocket_stress.zig"),
            .target = target,
            .optimize = optimize,
        });
        stress_mod.addImport("zhttp", mod);
        stress_mod.addImport("zwebsocket", dep.module("zwebsocket"));
        stress_mod.addImport("zhttp_ws_support", ws_support_mod);

        const stress_exe = b.addExecutable(.{
            .name = "zhttp-websocket-stress",
            .root_module = stress_mod,
        });
        const stress_run = b.addRunArtifact(stress_exe);
        if (b.args) |args| {
            stress_run.addArgs(args);
        }
        const stress_step = b.step("stress-websocket", "Run websocket churn/soak stress against the real upgrade path");
        stress_step.dependOn(&stress_run.step);

        const stress_tsan_mod = b.createModule(.{
            .root_source_file = b.path("benchmark/websocket_stress.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = true,
        });
        stress_tsan_mod.addImport("zhttp", mod);
        stress_tsan_mod.addImport("zwebsocket", dep.module("zwebsocket"));
        stress_tsan_mod.addImport("zhttp_ws_support", ws_support_mod);

        const stress_tsan_exe = b.addExecutable(.{
            .name = "zhttp-websocket-stress-tsan",
            .root_module = stress_tsan_mod,
        });
        const stress_tsan_run = b.addRunArtifact(stress_tsan_exe);
        if (b.args) |args| {
            stress_tsan_run.addArgs(args);
        }
        const stress_tsan_step = b.step("stress-websocket-tsan", "Run websocket stress harness under thread sanitizer");
        stress_tsan_step.dependOn(&stress_tsan_run.step);

        const soak_server_mod = b.createModule(.{
            .root_source_file = b.path("benchmark/websocket_soak_server.zig"),
            .target = target,
            .optimize = optimize,
        });
        soak_server_mod.addImport("zhttp", mod);
        soak_server_mod.addImport("zwebsocket", dep.module("zwebsocket"));
        soak_server_mod.addImport("zhttp_ws_support", ws_support_mod);

        const soak_server_exe = b.addExecutable(.{
            .name = "zhttp-websocket-soak-server",
            .root_module = soak_server_mod,
        });
        const install_soak_server = b.addInstallArtifact(soak_server_exe, .{});
        const soak_server_step = b.step("soak-websocket-server", "Build the external websocket soak server");
        soak_server_step.dependOn(&install_soak_server.step);
    }

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

    if (zws_dep) |dep| {
        const ws_support_mod = b.createModule(.{
            .root_source_file = b.path("websocket_support.zig"),
            .target = target,
            .optimize = optimize,
        });
        ws_support_mod.addImport("zhttp", mod);
        ws_support_mod.addImport("zwebsocket", dep.module("zwebsocket"));

        const exe_mod = b.createModule(.{
            .root_source_file = b.path("examples/websocket.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("zhttp", mod);
        exe_mod.addImport("zwebsocket", dep.module("zwebsocket"));
        exe_mod.addImport("zhttp_ws_support", ws_support_mod);

        const exe = b.addExecutable(.{
            .name = "zhttp-example-websocket",
            .root_module = exe_mod,
        });
        examples_step.dependOn(&exe.step);

        const run = b.addRunArtifact(exe);
        run.addArg("--smoke");
        examples_check_step.dependOn(&run.step);
    }
}
