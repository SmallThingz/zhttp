const std = @import("std");
const scripts = @import("scripts.zig");

/// Starts this executable.
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try std.process.currentPathAlloc(init.io, allocator);
    const env = init.environ_map;

    const conns = scripts.envInt(env, "CONNS", 1);
    const iters = scripts.envInt(env, "ITERS", 200000);
    const warmup = scripts.envInt(env, "WARMUP", 10000);
    const path = scripts.envString(env, "PATH_NAME", scripts.envString(env, "BENCH_PATH", "/plaintext"));
    const full_request = scripts.envBool(env, "FULL_REQUEST", false);
    const quiet = scripts.envBool(env, "QUIET", false);
    const fixed_bytes = scripts.envOptionalInt(env, "FIXED_BYTES");

    try scripts.ensureBenchBinary(init.io, allocator, root);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "./zig-out/bin/zhttp-bench");
    try args.append(allocator, "--mode=zhttp");
    try args.append(allocator, try std.fmt.allocPrint(allocator, "--conns={d}", .{conns}));
    try args.append(allocator, try std.fmt.allocPrint(allocator, "--iters={d}", .{iters}));
    try args.append(allocator, try std.fmt.allocPrint(allocator, "--warmup={d}", .{warmup}));
    try args.append(allocator, try std.fmt.allocPrint(allocator, "--path={s}", .{path}));
    if (full_request) try args.append(allocator, "--full-request");
    if (quiet) try args.append(allocator, "--quiet");
    if (fixed_bytes) |v| {
        try args.append(allocator, try std.fmt.allocPrint(allocator, "--fixed-bytes={d}", .{v}));
    }

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]
    while (it.next()) |arg_z| {
        try args.append(allocator, arg_z);
    }

    try scripts.runChecked(init.io, args.items, root, true);
}
