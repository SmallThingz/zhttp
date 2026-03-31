const std = @import("std");
const zhttp = @import("zhttp");
const common = @import("common.zig");
const ReqCtx = zhttp.ReqCtx;

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

fn usage() void {
    std.debug.print(
        \\echo_body
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-echo_body --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
        \\Endpoints:
        \\  POST /echo   (echoes request body; up to 1MiB; supports Expect: 100-continue)
        \\
    , .{});
}

const Echo = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};
    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const body = try req.bodyAll(1024 * 1024);
        return zhttp.Res.text(200, body);
    }
};

const SrvT = zhttp.Server(.{
    .middlewares = .{
        zhttp.middleware.Expect(.{}),
    },
    .routes = .{
        zhttp.post("/echo", Echo),
    },
});

/// Starts this executable.
pub fn main(init: std.process.Init) !void {
    var port: u16 = 8080;
    var smoke: bool = false;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next(); // argv[0]

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        }
        if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
            continue;
        }
        if (common.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "port")) {
                port = try std.fmt.parseInt(u16, kv.val, 10);
            } else {
                return error.UnknownArg;
            }
            continue;
        }
        return error.UnknownArg;
    }

    if (smoke) {
        const io = init.io;

        const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
        var actual_port: u16 = 0;

        var group: std.Io.Group = .init;
        var group_done = false;
        defer if (!group_done) {
            group.cancel(io);
            group.await(io) catch {};
        };
        try group.concurrent(io, struct {
            fn runServer(args: SrvT.RunArgs) std.Io.Cancelable!void {
                SrvT.run(args) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => std.debug.panic("example server run failed: {s}", .{@errorName(err)}),
                };
            }
        }.runServer, .{.{ .gpa = init.gpa, .io = io, .address = addr0, .ctx = {}, .actual_port_out = &actual_port }});
        while (actual_port == 0) {
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake);
        }

        const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(actual_port) };
        var stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        var close_stream = true;
        defer if (close_stream) stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [4 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        const req =
            "POST /echo HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Connection: close\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "hello";
        try sw.interface.writeAll(req);
        try sw.interface.flush();

        const interim = "HTTP/1.1 100 Continue\r\n\r\n";
        var got_interim: [interim.len]u8 = undefined;
        try sr.interface.readSliceAll(got_interim[0..]);
        try std.testing.expectEqualStrings(interim, got_interim[0..]);

        const resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: close\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 5\r\n" ++
            "\r\n" ++
            "hello";

        var got: [resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(resp, got[0..]);

        stream.close(io);
        close_stream = false;
        group.cancel(io);
        group.await(io) catch {};
        group_done = true;
        return;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    std.debug.print("listening on http://127.0.0.1:{d}\n", .{port});
    try SrvT.run(.{ .gpa = init.gpa, .io = init.io, .address = addr, .ctx = {} });
}
