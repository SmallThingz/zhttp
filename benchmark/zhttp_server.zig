const std = @import("std");
const zhttp = @import("zhttp");
const scripts = @import("scripts.zig");

const Plaintext = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};
    pub fn call(comptime _: zhttp.ReqCtx, req: anytype) !zhttp.response.Res {
        _ = req;
        return .{
            .headers = &.{
                .{ .name = "server", .value = "F" },
                .{ .name = "content-type", .value = "text/plain" },
                .{ .name = "date", .value = "Wed, 24 Feb 2021 12:00:00 GMT" },
            },
            .body = "Hello, World!",
        };
    }
};

fn usage() void {
    std.debug.print(
        \\zhttp-bench-server
        \\
        \\Usage:
        \\  zhttp-bench-server [--port=8081] [--reuse=1|0]
        \\
    , .{});
}

/// Starts this executable.
pub fn main(init: std.process.Init) !void {
    var port: u16 = 8081;
    const cpu_count = std.Thread.getCpuCount() catch 1;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next(); // argv[0]

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        }
        if (std.mem.eql(u8, arg, "--no-reuse")) continue;
        if (scripts.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "port")) {
                port = try std.fmt.parseInt(u16, kv.val, 10);
            } else if (!std.mem.eql(u8, kv.key, "reuse")) {
                return error.UnknownArg;
            }
            continue;
        }
        return error.UnknownArg;
    }

    const SrvT = zhttp.Server(.{
        .routes = .{
            zhttp.get("/plaintext", Plaintext),
        },
        .config = .{
            .listen_backlog = 65_535,
            .tcp_nodelay = true,
            // The no-reuse benchmark intentionally tears down every connection.
            // With the normal buffered response path, abortive close restores the
            // short-connection throughput that the benchmark is meant to measure.
            .abortive_close = true,
            .temp_workers = false,
            .max_temp_workers = 8,
            .temp_worker_connection_limit = 1_000_000,
        },
    });

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    try SrvT.run(.{
        .gpa = init.gpa,
        .io = init.io,
        .address = addr,
        .ctx = {},
        .permanent_workers = cpu_count,
    });
}
