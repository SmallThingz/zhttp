const std = @import("std");
const zhttp = @import("zhttp");
const common = @import("common.zig");

fn usage() void {
    std.debug.print(
        \\middleware
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-middleware --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
        \\Endpoints:
        \\  GET /public
        \\  GET /private   (requires Authorization: bearer ok)
        \\
    , .{});
}

const Auth = struct {
    pub const Info = zhttp.middleware.MiddlewareInfo{
        .name = "auth",
        .header = struct {
            authorization: zhttp.parse.Optional(zhttp.parse.String),
        },
    };

    pub fn call(comptime rctx: anytype, req: rctx.T()) !zhttp.Res {
        const auth = req.header(.authorization) orelse return zhttp.Res.text(401, "missing auth\n");
        if (!std.mem.eql(u8, auth, "bearer ok")) return zhttp.Res.text(403, "bad auth\n");
        return try rctx.next(req);
    }

    pub fn Override(comptime _: anytype) type {
        return struct {};
    }
};

fn public(comptime rctx: anytype, req: rctx.T()) !zhttp.Res {
    _ = req;
    return zhttp.Res.text(200, "public\n");
}

fn private(comptime rctx: anytype, req: rctx.T()) !zhttp.Res {
    _ = req;
    return zhttp.Res.text(200, "private\n");
}

const SrvT = zhttp.Server(.{
    .routes = .{
        zhttp.get("/public", public, .{}),
        zhttp.get("/private", private, .{
            .middlewares = .{Auth},
        }),
    },
});

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
            "GET /public HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /private HTTP/1.1\r\nHost: x\r\nAuthorization: bearer ok\r\n\r\n";

        try sw.interface.writeAll(req);
        try sw.interface.flush();

        const resp1 =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 7\r\n" ++
            "\r\n" ++
            "public\n";

        const resp2 =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 8\r\n" ++
            "\r\n" ++
            "private\n";

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
