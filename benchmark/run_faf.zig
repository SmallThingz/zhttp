const std = @import("std");
const scripts = @import("scripts.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(root);

    var bench_bin_arg: ?[]const u8 = null;
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]
    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.startsWith(u8, arg, "--bench-bin=")) {
            bench_bin_arg = arg["--bench-bin=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            return;
        }
        return error.UnknownArg;
    }

    const env = init.environ_map;
    const port = @as(u16, @intCast(scripts.envInt(env, "PORT", 8080)));
    const conns = scripts.envInt(env, "CONNS", 1);
    const iters = scripts.envInt(env, "ITERS", 200000);
    const warmup = scripts.envInt(env, "WARMUP", 10000);
    const full_request = scripts.envBool(env, "FULL_REQUEST", false);

    const faf_dir = scripts.envString(env, "FAF_DIR", ".zig-cache/faf-example");
    const faf_core_dir = scripts.envString(env, "FAF_CORE_DIR", ".zig-cache/faf");

    const rustc_env = env.get("RUSTC_BIN") orelse env.get("RUSTC");
    const bench_bin = bench_bin_arg orelse env.get("BENCH_BIN");
    const rustc_bin = rustc_env orelse "rustc";

    const cfg: scripts.BenchConfig = .{
        .port = port,
        .conns = conns,
        .iters = iters,
        .warmup = warmup,
        .full_request = full_request,
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
