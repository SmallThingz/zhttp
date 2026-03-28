const std = @import("std");
const zhttp = @import("zhttp");
const common = @import("common.zig");
const ReqCtx = zhttp.ReqCtx;

fn usage() void {
    std.debug.print(
        \\basic_server
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-basic_server --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
    , .{});
}

fn health(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
    _ = req;
    return zhttp.Res.text(200, "ok");
}

fn hello(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
    const name_opt = req.queryParam(.name) orelse "world";
    const body = try std.fmt.allocPrint(req.allocator(), "hello {s}\n", .{name_opt});
    return zhttp.Res.text(200, body);
}

fn user(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
    const id = req.paramValue(.id);
    const host = req.header(.host) orelse "(no host)";
    const body = try std.fmt.allocPrint(req.allocator(), "id={d} host={s}\n", .{ id, host });
    return zhttp.Res.text(200, body);
}

const SrvT = zhttp.Server(.{
    .routes = .{
        zhttp.get("/health", health, .{}),
        zhttp.get("/hello", hello, .{
            .query = struct {
                name: zhttp.parse.Optional(zhttp.parse.String),
            },
        }),
        zhttp.get("/users/{id}", user, .{
            .headers = struct {
                host: zhttp.parse.Optional(zhttp.parse.String),
            },
            .params = struct {
                id: zhttp.parse.Int(u64),
            },
        }),
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
        var threaded = std.Io.Threaded.init(init.gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
        var server = try SrvT.init(init.gpa, io, addr0, {});
        defer server.deinit();
        const actual_port: u16 = server.listener.socket.address.getPort();

        var group: std.Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, SrvT.run, .{&server});

        const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(actual_port) };
        var stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [4 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        const req =
            "GET /hello?name=zig HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /users/42 HTTP/1.1\r\nHost: example\r\n\r\n";

        try sw.interface.writeAll(req);
        try sw.interface.flush();

        const resp1 =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 10\r\n" ++
            "\r\n" ++
            "hello zig\n";

        const resp2 =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 19\r\n" ++
            "\r\n" ++
            "id=42 host=example\n";

        var got1: [resp1.len]u8 = undefined;
        var got2: [resp2.len]u8 = undefined;
        try sr.interface.readSliceAll(got1[0..]);
        try sr.interface.readSliceAll(got2[0..]);
        try std.testing.expectEqualStrings(resp1, got1[0..]);
        try std.testing.expectEqualStrings(resp2, got2[0..]);

        group.cancel(io);
        group.await(io) catch {};
        return;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var server = try SrvT.init(init.gpa, init.io, addr, {});
    defer server.deinit();

    std.debug.print("listening on http://127.0.0.1:{d}\n", .{port});
    try server.run();
}
