const std = @import("std");
const scripts = @import("scripts.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(root);

    var bench_bin_arg: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var port: ?u16 = null;
    var conns: ?usize = null;
    var iters: ?usize = null;
    var warmup: ?usize = null;
    var fixed_bytes: ?usize = null;
    var full_request: ?bool = null;
    var quiet: ?bool = null;
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
            full_request = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            continue;
        }
        if (scripts.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "host")) {
                host = kv.val;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "path")) {
                path = kv.val;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "port")) {
                port = @as(u16, @intCast(std.fmt.parseInt(usize, kv.val, 10) catch return error.UnknownArg));
                continue;
            }
            if (std.mem.eql(u8, kv.key, "conns")) {
                conns = std.fmt.parseInt(usize, kv.val, 10) catch return error.UnknownArg;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "iters")) {
                iters = std.fmt.parseInt(usize, kv.val, 10) catch return error.UnknownArg;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "warmup")) {
                warmup = std.fmt.parseInt(usize, kv.val, 10) catch return error.UnknownArg;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "fixed-bytes")) {
                fixed_bytes = std.fmt.parseInt(usize, kv.val, 10) catch return error.UnknownArg;
                continue;
            }
            if (std.mem.eql(u8, kv.key, "full-request")) {
                full_request = !std.mem.eql(u8, kv.val, "0");
                continue;
            }
            if (std.mem.eql(u8, kv.key, "quiet")) {
                quiet = !std.mem.eql(u8, kv.val, "0");
                continue;
            }
            if (std.mem.eql(u8, kv.key, "mode")) {
                continue;
            }
        }
        if (std.mem.eql(u8, arg, "--help")) return;
        return error.UnknownArg;
    }

    const env = init.environ_map;
    const port_val = port orelse @as(u16, @intCast(scripts.envInt(env, "PORT", 8080)));
    const conns_val = conns orelse scripts.envInt(env, "CONNS", 1);
    const iters_val = iters orelse scripts.envInt(env, "ITERS", 200000);
    const warmup_val = warmup orelse scripts.envInt(env, "WARMUP", 10000);
    const full_request_val = full_request orelse scripts.envBool(env, "FULL_REQUEST", false);
    const quiet_val = quiet orelse scripts.envBool(env, "QUIET", false);
    const host_val = host orelse scripts.envString(env, "HOST", "127.0.0.1");
    const path_val = path orelse (env.get("PATH_NAME") orelse env.get("BENCH_PATH") orelse "/plaintext");
    const fixed_val: ?usize = fixed_bytes orelse if (env.get("FIXED_BYTES")) |v| (std.fmt.parseInt(usize, v, 10) catch null) else null;

    const faf_dir = scripts.envString(env, "FAF_DIR", ".zig-cache/faf-example");
    const faf_core_dir = scripts.envString(env, "FAF_CORE_DIR", ".zig-cache/faf");

    const rustc_env = env.get("RUSTC_BIN") orelse env.get("RUSTC");
    const bench_bin = bench_bin_arg orelse env.get("BENCH_BIN");
    const rustc_bin = rustc_env orelse "rustc";

    const cfg: scripts.BenchConfig = .{
        .port = port_val,
        .host = host_val,
        .path = path_val,
        .conns = conns_val,
        .iters = iters_val,
        .warmup = warmup_val,
        .full_request = full_request_val,
        .fixed_bytes = fixed_val,
        .quiet = quiet_val,
    };
    scripts.runFaf(init.io, allocator, cfg, faf_dir, faf_core_dir, rustc_bin, bench_bin, init.minimal.environ, root) catch |err| switch (err) {
        error.CargoMissing => {
            var buffer: [256]u8 = undefined;
            const stderr_file = std.Io.File.stderr();
            var stderr = stderr_file.writer(init.io, &buffer);
            try stderr.interface.writeAll("cargo not found; FaF example requires Rust toolchain.\n");
            try stderr.interface.writeAll("Install Rust (cargo + rustc), then re-run.\n");
            return err;
        },
        else => return err,
    };
}
