const std = @import("std");
const zhttp = @import("zhttp");
const zws = @import("zwebsocket");
const ws = @import("zhttp_ws_support");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const WsHeaders = ws.WsHeaders;
const Auth = ws.Auth;
const WsRunner = ws.WsRunner;
const upgrade = ws.upgrade;

pub const SrvT = zhttp.Server(.{
    .routes = .{
        zhttp.get("/ws", upgrade, .{
            .headers = WsHeaders,
            .middlewares = .{
                Auth,
                ws.Origin,
            },
            .upgrade = WsRunner,
        }),
    },
});

fn usage() void {
    std.debug.print(
        \\websocket
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-websocket --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
        \\Endpoint:
        \\  GET /ws   (requires Authorization: bearer ok, Origin, and X-Allow-WS: yes)
        \\
    , .{});
}

pub fn runSmoke(gpa: Allocator, io: Io) !void {
    const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.init(gpa, io, addr0, {});
    defer server.deinit();
    const actual_port: u16 = server.listener.socket.address.getPort();

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, SrvT.run, .{&server});

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(actual_port) };
    var stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [1024]u8 = undefined;
    var wb: [1024]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const req =
        "GET /ws HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Origin: http://localhost\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Sec-WebSocket-Key: " ++ key ++ "\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Authorization: bearer ok\r\n" ++
        "X-Allow-WS: yes\r\n" ++
        "\r\n";

    try sw.interface.writeAll(req);
    try sw.interface.flush();

    const accept_key = try zws.computeAcceptKey(key);
    try ws.expectServerHandshakeResponse(&sr.interface, accept_key[0..]);

    var conn = zws.ClientConn.init(&sr.interface, &sw.interface, .{});
    try conn.writePing("!");
    try conn.writeText("hello");
    try conn.writeText("again");
    try conn.writeClose(1000, "done");
    try conn.flush();

    var frame_buf: [256]u8 = undefined;
    const pong = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(zws.Opcode.pong, pong.header.opcode);
    try std.testing.expectEqualStrings("!", pong.payload);

    const msg1 = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(zws.Opcode.text, msg1.header.opcode);
    try std.testing.expectEqualStrings("user-7: hello", msg1.payload);

    const msg2 = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(zws.Opcode.text, msg2.header.opcode);
    try std.testing.expectEqualStrings("user-7: again", msg2.payload);

    const close_frame = try conn.readFrame(frame_buf[0..]);
    try std.testing.expectEqual(zws.Opcode.close, close_frame.header.opcode);
    const parsed_close = try zws.parseClosePayload(close_frame.payload, true);
    try std.testing.expectEqual(@as(?u16, 1000), parsed_close.code);
    try std.testing.expectEqualStrings("done", parsed_close.reason);

    group.cancel(io);
    group.await(io) catch {};
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8080;
    var smoke: bool = false;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

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
        try runSmoke(init.gpa, threaded.io());
        return;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var server = try SrvT.init(init.gpa, init.io, addr, {});
    defer server.deinit();

    std.debug.print("listening for websocket upgrades on http://127.0.0.1:{d}/ws\n", .{port});
    try server.run();
}
