const std = @import("std");
const scripts = @import("scripts.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(root);

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
    const cfg: scripts.BenchConfig = .{
        .port = port orelse @as(u16, @intCast(scripts.envInt(env, "PORT", 8081))),
        .host = host orelse scripts.envString(env, "HOST", "127.0.0.1"),
        .path = path orelse scripts.envString(env, "PATH_NAME", scripts.envString(env, "BENCH_PATH", "/plaintext")),
        .conns = conns orelse scripts.envInt(env, "CONNS", 1),
        .iters = iters orelse scripts.envInt(env, "ITERS", 200000),
        .warmup = warmup orelse scripts.envInt(env, "WARMUP", 10000),
        .full_request = full_request orelse scripts.envBool(env, "FULL_REQUEST", false),
        .fixed_bytes = fixed_bytes,
        .quiet = quiet orelse false,
    };
    try scripts.runZhttpExternal(init.io, allocator, cfg, root, init.minimal.environ);
}
