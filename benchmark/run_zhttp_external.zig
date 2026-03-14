const std = @import("std");
const scripts = @import("scripts.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.process.currentPathAlloc(init.io, allocator);
    defer allocator.free(root);

    const env = init.environ_map;
    const port = @as(u16, @intCast(scripts.envInt(env, "PORT", 8081)));
    const conns = scripts.envInt(env, "CONNS", 1);
    const iters = scripts.envInt(env, "ITERS", 200000);
    const warmup = scripts.envInt(env, "WARMUP", 10000);
    const full_request = scripts.envBool(env, "FULL_REQUEST", false);

    const cfg: scripts.BenchConfig = .{
        .port = port,
        .conns = conns,
        .iters = iters,
        .warmup = warmup,
        .full_request = full_request,
    };
    try scripts.runZhttpExternal(init.io, allocator, cfg, root);
}
