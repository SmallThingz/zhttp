const std = @import("std");
const zhttp = @import("zhttp");
const scripts = @import("scripts.zig");

const PlaintextResponse = struct {
    const keep_alive_body =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "\r\n" ++
        "Hello, World!";
    const keep_alive_head =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "\r\n";
    const close_body =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Connection: close\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "\r\n" ++
        "Hello, World!";
    const close_head =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Connection: close\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "\r\n";

    pub fn write(_: @This(), w: *std.Io.Writer, keep_alive: bool, send_body: bool) !void {
        try w.writeAll(if (keep_alive)
            if (send_body) keep_alive_body else keep_alive_head
        else if (send_body)
            close_body
        else
            close_head);
    }
};

const Plaintext = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};
    pub fn call(comptime _: zhttp.ReqCtx, req: anytype) !PlaintextResponse {
        _ = req;
        return .{};
    }
};

fn usage() void {
    std.debug.print(
        \\zhttp-bench-server
        \\
        \\Usage:
        \\  zhttp-bench-server [--port=8081]
        \\
    , .{});
}

/// Starts this executable.
pub fn main(init: std.process.Init) !void {
    var port: u16 = 8081;
    const permanent_workers = @max(std.Thread.getCpuCount() catch 1, 16);

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next(); // argv[0]

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        }
        if (scripts.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "port")) {
                port = try std.fmt.parseInt(u16, kv.val, 10);
            } else {
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
        .permanent_workers = permanent_workers,
    });
}
