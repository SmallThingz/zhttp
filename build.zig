const std = @import("std");

const Example = struct {
    name: []const u8,
    path: []const u8,
    uses_zws: bool,
};

fn discoverExamples(b: *std.Build, allocator: std.mem.Allocator) ![]Example {
    const io = b.graph.io;
    var dir = try b.build_root.handle.openDir(io, "examples", .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    var out: std.ArrayList(Example) = .empty;
    errdefer {
        for (out.items) |ex| {
            allocator.free(ex.name);
            allocator.free(ex.path);
        }
        out.deinit(allocator);
    }

    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "examples/{s}", .{entry.name});
        errdefer allocator.free(path);

        const src = try b.build_root.handle.readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(src);

        const has_main = std.mem.indexOf(u8, src, "pub fn main(") != null or std.mem.indexOf(u8, src, "fn main(") != null;
        if (!has_main) continue;

        const name = try allocator.dupe(u8, entry.name[0 .. entry.name.len - ".zig".len]);
        errdefer allocator.free(name);

        const uses_zws = std.mem.indexOf(u8, src, "@import(\"zwebsocket\")") != null;
        try out.append(allocator, .{
            .name = name,
            .path = path,
            .uses_zws = uses_zws,
        });
    }

    std.sort.heap(Example, out.items, {}, struct {
        fn lessThan(_: void, a: Example, ex: Example) bool {
            return std.mem.lessThan(u8, a.path, ex.path);
        }
    }.lessThan);

    return out.toOwnedSlice(allocator);
}

/// Configures build steps for this package.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize_thread", "Enable ThreadSanitizer instrumentation") orelse false;
    const static_libc = b.option(bool, "static_libc", "Link libc statically (default: true)") orelse true;
    const effective_static_libc = if (sanitize_thread) false else static_libc;
    const mod = b.addModule("zhttp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .sanitize_thread = sanitize_thread,
    });
    const zws_dep = b.dependency("zwebsocket", .{
        .target = target,
        .optimize = optimize,
    });
    const zstd_dep = b.dependency("libzstd", .{
        .target = target,
        .optimize = optimize,
        .static_libc = effective_static_libc,
    });
    const brotli_dep = b.dependency("libbrotli", .{
        .target = target,
        .optimize = optimize,
        .static_libc = effective_static_libc,
    });

    const zstd_mod = zstd_dep.module("libzstd");
    const brotli_mod = brotli_dep.module("libbrotli");
    const zws_mod = zws_dep.module("zwebsocket");
    mod.addImport("zwebsocket", zws_mod);
    mod.addImport("libzstd", zstd_mod);
    mod.addImport("libbrotli", brotli_mod);

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_root.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
        }),
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    mod_tests.root_module.addImport("zwebsocket", zws_mod);
    mod_tests.root_module.addImport("libzstd", zstd_mod);
    mod_tests.root_module.addImport("libbrotli", brotli_mod);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.addArgs(&.{"--zhttp-skip=loopback listen preflight"});
    if (b.args) |args| {
        run_mod_tests.addArgs(args);
    }
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const test_flake_exe = b.addExecutable(.{
        .name = "zhttp-test-flake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/run_test_flake.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const test_flake_run = b.addRunArtifact(test_flake_exe);
    test_flake_run.addPrefixedArtifactArg("--test-bin=", mod_tests);
    if (b.args) |args| {
        test_flake_run.addArgs(args);
    }
    const test_flake_step = b.step("test-flake", "Hunt flaky tests deterministically with seeded runs");
    test_flake_step.dependOn(&test_flake_run.step);

    const bench_exe = b.addExecutable(.{
        .name = "zhttp-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/bench.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zhttp", .module = mod },
            },
        }),
    });

    const bench_step = b.step("bench", "Run benchmarks");
    const bench_zhttp_exe = b.addExecutable(.{
        .name = "zhttp-bench-zhttp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/run_zhttp_external.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const bench_zhttp_run = b.addRunArtifact(bench_zhttp_exe);
    if (b.args) |args| {
        bench_zhttp_run.addArgs(args);
    }
    bench_zhttp_run.step.dependOn(&bench_exe.step);
    bench_step.dependOn(&bench_zhttp_run.step);

    const bench_compare_exe = b.addExecutable(.{
        .name = "zhttp-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/run_compare.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
        }),
    });
    const bench_compare_run = b.addRunArtifact(bench_compare_exe);
    bench_compare_run.addPrefixedArtifactArg("--bench-bin=", bench_exe);
    if (b.args) |args| {
        bench_compare_run.addArgs(args);
    }
    bench_compare_run.step.dependOn(&bench_exe.step);
    const bench_compare_step = b.step("bench-compare", "Run fair zhttp-vs-FaF benchmark and sync README summary");
    bench_compare_step.dependOn(&bench_compare_run.step);

    const examples_step = b.step("examples", "Build all examples");
    const examples_check_step = b.step("examples-check", "Run all examples with --smoke");

    const examples = discoverExamples(b, b.allocator) catch |err| {
        std.debug.panic("failed to enumerate examples directory: {s}", .{@errorName(err)});
    };
    defer {
        for (examples) |ex| {
            b.allocator.free(ex.name);
            b.allocator.free(ex.path);
        }
        b.allocator.free(examples);
    }

    var prev_examples_check_step: ?*std.Build.Step = null;

    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = b.fmt("zhttp-example-{s}", .{ex.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
        });
        exe.root_module.addImport("zhttp", mod);
        if (ex.uses_zws) {
            exe.root_module.addImport("zwebsocket", zws_mod);
        }
        examples_step.dependOn(&exe.step);

        const run = b.addRunArtifact(exe);
        run.addArg("--smoke");
        if (prev_examples_check_step) |prev| {
            run.step.dependOn(prev);
        }
        examples_check_step.dependOn(&run.step);
        prev_examples_check_step = &run.step;
    }
}
