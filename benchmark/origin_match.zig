const std = @import("std");
const zhttp = @import("zhttp");
const scripts = @import("scripts.zig");

comptime {
    @setEvalBranchQuota(200_000);
}

const allowed_origins = [_][]const u8{
    "https://app.example.com",
    "https://admin.example.com",
    "https://api.example.com",
    "https://cdn.example.com",
    "https://socket.example.com",
    "https://chat.example.com",
    "https://dashboard.example.com",
    "https://billing.example.com",
    "https://auth.example.com",
    "https://staging.example.com",
    "https://preview-01.example.com",
    "https://preview-02.example.com",
    "https://preview-03.example.com",
    "https://preview-04.example.com",
    "https://preview-05.example.com",
    "https://preview-06.example.com",
    "http://localhost",
    "http://localhost:3000",
    "http://localhost:4173",
    "http://127.0.0.1",
    "http://127.0.0.1:3000",
    "http://127.0.0.1:5173",
    "http://127.0.0.1:8080",
    "http://devbox.internal",
    "https://tenant-a.example.net",
    "https://tenant-b.example.net",
    "https://tenant-c.example.net",
    "https://tenant-d.example.net",
    "https://eu-west-1.example.org",
    "https://us-east-1.example.org",
    "https://ap-southeast-2.example.org",
    "https://mobile.example.app",
};

const probes = [_][]const u8{
    "https://app.example.com",
    "https://admin.example.com",
    "https://api.example.com",
    "https://preview-05.example.com",
    "http://localhost",
    "http://127.0.0.1:5173",
    "https://mobile.example.app",
    "https://evil.example.com",
    "https://api.example.com:443",
    "http://localhost:4000",
    "http://127.0.0.1:9000",
    "https://preview-99.example.com",
    "https://tenant-z.example.net",
    "https://us-west-2.example.org",
    "wss://app.example.com",
    "null",
};

const Tree = zhttp.middleware.OriginDecisionTree(allowed_origins[0..]);
const Hash = zhttp.middleware.OriginHashMatcher(allowed_origins[0..]);

var sink: usize = 0;

fn nowNs() u64 {
    const linux = std.os.linux;
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    if (rc != 0) std.process.fatal("clock_gettime failed", .{});
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn runTree(iters: usize) !u64 {
    var hits: usize = 0;
    const start = nowNs();
    const probe_list = probes[0..];
    for (0..iters) |_| {
        for (probe_list) |probe| {
            hits += @intFromBool(Tree.contains(probe));
        }
    }
    sink = hits;
    std.mem.doNotOptimizeAway(sink);
    return nowNs() - start;
}

fn runHash(iters: usize) !u64 {
    var hits: usize = 0;
    const start = nowNs();
    const probe_list = probes[0..];
    for (0..iters) |_| {
        for (probe_list) |probe| {
            hits += @intFromBool(Hash.contains(probe));
        }
    }
    sink = hits;
    std.mem.doNotOptimizeAway(sink);
    return nowNs() - start;
}

fn parseUsize(arg: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, arg, 10);
}

fn printResult(name: []const u8, elapsed_ns: u64, total_lookups: usize) void {
    const ns_per_lookup = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_lookups));
    std.debug.print("{s}: {d} ns total, {d:.3} ns/lookup\n", .{ name, elapsed_ns, ns_per_lookup });
}

/// Starts this executable.
pub fn main(init: std.process.Init) !void {
    var iters: usize = 2_000_000;
    var warmup: usize = 200_000;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (scripts.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "iters")) {
                iters = try parseUsize(kv.val);
            } else if (std.mem.eql(u8, kv.key, "warmup")) {
                warmup = try parseUsize(kv.val);
            } else {
                return error.UnknownArg;
            }
        } else {
            return error.UnknownArg;
        }
    }

    _ = try runTree(warmup);
    _ = try runHash(warmup);

    const total_lookups = iters * probes.len;
    const tree_elapsed = try runTree(iters);
    const map_elapsed = try runHash(iters);

    std.debug.print(
        "origin benchmark: {d} allowed origins, {d} probes, {d} total lookups\n",
        .{ allowed_origins.len, probes.len, total_lookups },
    );
    printResult("decision_tree", tree_elapsed, total_lookups);
    printResult("origin_hash_matcher", map_elapsed, total_lookups);

    const winner = if (tree_elapsed <= map_elapsed) "decision_tree" else "origin_hash_matcher";
    std.debug.print("winner: {s}\n", .{winner});
}
