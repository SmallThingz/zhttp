const std = @import("std");
const scripts = @import("scripts.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(root);

    const env = init.environ_map;
    const conns = scripts.envInt(env, "CONNS", 16);
    const iters = scripts.envInt(env, "ITERS", 200000);
    const warmup = scripts.envInt(env, "WARMUP", 10000);
    const full_request = scripts.envBool(env, "FULL_REQUEST", true);

    var out_buffer: [256]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(init.io, &out_buffer);
    try stdout.interface.writeAll("== zhttp ==\n");
    const zhttp_cfg: scripts.BenchConfig = .{
        .port = 8081,
        .conns = conns,
        .iters = iters,
        .warmup = warmup,
        .full_request = full_request,
    };
    try scripts.runZhttpExternal(init.io, allocator, zhttp_cfg, root);

    try stdout.interface.writeAll("\n== FaF ==\n");
    const faf_cfg: scripts.BenchConfig = .{
        .port = 8080,
        .conns = conns,
        .iters = iters,
        .warmup = warmup,
        .full_request = full_request,
    };

    const faf_dir = scripts.envString(env, "FAF_DIR", ".zig-cache/faf-example");
    const faf_core_dir = scripts.envString(env, "FAF_CORE_DIR", ".zig-cache/faf");
    const rustc_env = env.get("RUSTC_BIN") orelse env.get("RUSTC");
    const rustc_bin = rustc_env orelse "rustc";

    scripts.runFaf(init.io, allocator, faf_cfg, faf_dir, faf_core_dir, rustc_bin, init.minimal.environ, root) catch |err| switch (err) {
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
