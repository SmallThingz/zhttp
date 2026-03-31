const std = @import("std");
const scripts = @import("scripts.zig");

fn resolveRoot(init: std.process.Init, allocator: std.mem.Allocator) ![]u8 {
    if (init.environ_map.get("PWD")) |pwd| return allocator.dupe(u8, pwd);
    return std.process.currentPathAlloc(init.io, allocator);
}

fn reportContextError(context: []const u8, err: anyerror) void {
    std.debug.print("{s} failed: {s}\n", .{ context, @errorName(err) });
}

fn reportNetworkRestricted() void {
    std.debug.print(
        "benchmark socket operations are blocked in this environment (NetworkRestricted / EPERM)\n",
        .{},
    );
}

/// Starts this executable.
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try resolveRoot(init, allocator);
    defer allocator.free(root);

    var bench_bin_arg: ?[]const u8 = null;
    var host_arg: ?[]const u8 = null;
    var path_arg: ?[]const u8 = null;
    var conns_arg: ?usize = null;
    var iters_arg: ?usize = null;
    var warmup_arg: ?usize = null;
    var full_request_arg: ?bool = null;
    var reuse_arg: ?bool = null;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]
    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.startsWith(u8, arg, "--bench-bin=")) {
            bench_bin_arg = arg["--bench-bin=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--full-request")) {
            full_request_arg = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-reuse")) {
            reuse_arg = false;
            continue;
        }
        if (scripts.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "host")) {
                host_arg = kv.val;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "path")) {
                path_arg = kv.val;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "conns")) {
                conns_arg = std.fmt.parseInt(usize, kv.val, 10) catch return error.UnknownArg;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "iters")) {
                iters_arg = std.fmt.parseInt(usize, kv.val, 10) catch return error.UnknownArg;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "warmup")) {
                warmup_arg = std.fmt.parseInt(usize, kv.val, 10) catch return error.UnknownArg;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "full-request")) {
                full_request_arg = !std.mem.eql(u8, kv.val, "0");
                continue;
            }
            if (std.mem.eql(u8, kv.key, "reuse")) {
                reuse_arg = !std.mem.eql(u8, kv.val, "0");
                continue;
            }
            if (std.mem.eql(u8, kv.key, "mode")) continue;
        }
        if (std.mem.eql(u8, arg, "--help")) return;
        return error.UnknownArg;
    }

    const env = init.environ_map;
    const host = host_arg orelse scripts.envString(env, "HOST", "127.0.0.1");
    const path = path_arg orelse scripts.envString(env, "PATH_NAME", scripts.envString(env, "BENCH_PATH", "/plaintext"));
    const conns = conns_arg orelse scripts.envInt(env, "CONNS", 16);
    const iters = iters_arg orelse scripts.envInt(env, "ITERS", 20000);
    const warmup = warmup_arg orelse scripts.envInt(env, "WARMUP", 10000);
    const full_request = full_request_arg orelse scripts.envBool(env, "FULL_REQUEST", true);
    const reuse = reuse_arg orelse scripts.envBool(env, "REUSE", true);

    const zhttp_cfg: scripts.BenchConfig = .{
        .port = 8081,
        .host = host,
        .path = path,
        .conns = conns,
        .iters = iters,
        .warmup = warmup,
        .full_request = full_request,
        .reuse = reuse,
    };
    const zhttp_res = scripts.runZhttpExternal(init.io, allocator, zhttp_cfg, root, init.minimal.environ) catch |err| {
        if (err == error.NetworkRestricted) reportNetworkRestricted();
        reportContextError("runZhttpExternal", err);
        return err;
    };

    const faf_cfg: scripts.BenchConfig = .{
        .port = 8080,
        .host = host,
        .path = path,
        .conns = conns,
        .iters = iters,
        .warmup = warmup,
        .full_request = full_request,
        .reuse = reuse,
        .fixed_bytes = if (reuse) zhttp_res.fixed_bytes else null,
    };

    const faf_dir = scripts.envString(env, "FAF_DIR", ".zig-cache/faf-example");
    const faf_core_dir = scripts.envString(env, "FAF_CORE_DIR", ".zig-cache/faf");
    const rustc_env = env.get("RUSTC_BIN") orelse env.get("RUSTC");
    const rustc_bin = rustc_env orelse "rustc";
    const bench_bin = bench_bin_arg orelse env.get("BENCH_BIN");

    const faf_res = scripts.runFaf(init.io, allocator, faf_cfg, faf_dir, faf_core_dir, rustc_bin, bench_bin, init.minimal.environ, root) catch |err| switch (err) {
        error.CargoMissing => {
            var buffer: [256]u8 = undefined;
            const stderr_file = std.Io.File.stderr();
            var stderr = stderr_file.writer(init.io, &buffer);
            try stderr.interface.writeAll("cargo not found; FaF example requires Rust toolchain.\n");
            try stderr.interface.writeAll("Install Rust (cargo + rustc), then re-run.\n");
            return err;
        },
        else => {
            if (err == error.NetworkRestricted) reportNetworkRestricted();
            reportContextError("runFaf", err);
            return err;
        },
    };
    if (reuse and zhttp_res.fixed_bytes != faf_res.fixed_bytes) return error.FixedBytesMismatch;

    const compare_cfg: scripts.CompareConfig = .{
        .host = host,
        .path = path,
        .conns = conns,
        .iters = iters,
        .warmup = warmup,
        .full_request = full_request,
        .reuse = reuse,
    };
    scripts.writeCompareSnapshotAndSyncReadme(init.io, allocator, root, compare_cfg, zhttp_res, faf_res) catch |err| {
        reportContextError("writeCompareSnapshotAndSyncReadme", err);
        return err;
    };
}
