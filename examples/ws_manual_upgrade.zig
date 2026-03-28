const std = @import("std");
const zhttp = @import("zhttp");
const zws = @import("zwebsocket");
const common = @import("common.zig");
const ReqCtx = zhttp.ReqCtx;

const Io = std.Io;

fn usage() void {
    std.debug.print(
        \\ws_manual_upgrade
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-ws_manual_upgrade --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
        \\Endpoint:
        \\  GET /ws   (requires header: x-auth: secret)
        \\
        \\Notes:
        \\  - HTTP handshake validation is done in userspace via zwebsocket.
        \\  - `zhttp.upgrade.websocketResponse(...)` builds the 101 websocket response.
        \\  - route .upgrade_handler owns upgraded connection lifecycle.
        \\
    , .{});
}

const WsHeaders = struct {
    /// Stores `connection`.
    connection: zhttp.parse.Optional(zhttp.parse.String),
    /// Stores `upgrade`.
    upgrade: zhttp.parse.Optional(zhttp.parse.String),
    /// Stores `sec_websocket_key`.
    sec_websocket_key: zhttp.parse.Optional(zhttp.parse.String),
    /// Stores `sec_websocket_version`.
    sec_websocket_version: zhttp.parse.Optional(zhttp.parse.String),
    /// Stores `sec_websocket_protocol`.
    sec_websocket_protocol: zhttp.parse.Optional(zhttp.parse.String),
    /// Stores `sec_websocket_extensions`.
    sec_websocket_extensions: zhttp.parse.Optional(zhttp.parse.String),
    /// Stores `origin`.
    origin: zhttp.parse.Optional(zhttp.parse.String),
    /// Stores `host`.
    host: zhttp.parse.Optional(zhttp.parse.String),
    /// Stores `x_auth`.
    x_auth: zhttp.parse.Optional(zhttp.parse.String),
};

const Handshake = struct {
    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const auth = req.header(.x_auth) orelse return zhttp.Res.text(401, "missing x-auth\n");
        if (!std.mem.eql(u8, auth, "secret")) return zhttp.Res.text(403, "bad x-auth\n");

        const hs_req: zws.ServerHandshakeRequest = .{
            .method = req.method,
            .is_http_11 = req.baseConst().version == .http11,
            .connection = req.header(.connection),
            .upgrade = req.header(.upgrade),
            .sec_websocket_key = req.header(.sec_websocket_key),
            .sec_websocket_version = req.header(.sec_websocket_version),
            .sec_websocket_protocol = req.header(.sec_websocket_protocol),
            .sec_websocket_extensions = req.header(.sec_websocket_extensions),
            .origin = req.header(.origin),
            .host = req.header(.host),
        };

        const accepted = zws.acceptServerHandshake(hs_req, .{}) catch |err| switch (err) {
            error.UnsupportedWebSocketVersion => return .{
                .status = @enumFromInt(426),
                .headers = &.{.{ .name = "sec-websocket-version", .value = "13" }},
                .body = "unsupported websocket version\n",
            },
            else => return zhttp.Res.text(400, "bad websocket handshake\n"),
        };

        return zhttp.upgrade.websocketResponseWithAccept(req.allocator(), accepted.accept_key[0..], .{
            .subprotocol = accepted.selected_subprotocol,
            .extensions = accepted.selected_extensions,
        });
    }
};

fn closeForProtocolError(conn: *zws.ServerConn, w: *Io.Writer, err: anyerror) void {
    const code: ?u16 = switch (err) {
        error.EndOfStream, error.ConnectionClosed, error.ReadFailed, error.WriteFailed => null,
        error.InvalidUtf8 => 1007,
        error.FrameTooLarge, error.MessageTooLarge => 1009,
        error.OutOfMemory, error.Timeout => 1011,
        else => 1002,
    };
    if (code) |c| {
        conn.writeClose(c, "") catch {};
        w.flush() catch {};
    }
}

fn onUpgrade(
    server: anytype,
    stream: *const std.Io.net.Stream,
    r: *Io.Reader,
    w: *Io.Writer,
    _: zhttp.request.RequestLine,
    _: zhttp.Res,
) void {
    defer stream.close(server.io);

    var conn = zws.ServerConn.init(r, w, .{
        .max_frame_payload_len = 1024 * 1024,
        .max_message_payload_len = 1024 * 1024,
    });
    var message_buf: [128 * 1024]u8 = undefined;

    while (true) {
        const msg = conn.readMessage(message_buf[0..]) catch |err| {
            closeForProtocolError(&conn, w, err);
            return;
        };
        switch (msg.opcode) {
            .text => conn.writeText(msg.payload) catch |err| {
                closeForProtocolError(&conn, w, err);
                return;
            },
            .binary => conn.writeBinary(msg.payload) catch |err| {
                closeForProtocolError(&conn, w, err);
                return;
            },
        }
        w.flush() catch return;
    }
}

const Server = zhttp.Server(.{
    .routes = .{
        zhttp.get("/ws", Handshake, .{
            .headers = WsHeaders,
            .upgrade_handler = onUpgrade,
        }),
    },
});

/// Starts this executable.
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
        const io = threaded.io();

        const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
        var server = try Server.init(init.gpa, io, addr0, {});
        defer server.deinit();
        const actual_port: u16 = server.listener.socket.address.getPort();

        var group: std.Io.Group = .init;
        defer group.cancel(io);
        try group.concurrent(io, Server.run, .{&server});

        const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(actual_port) };
        var stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [4 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        const req =
            "GET /ws HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "X-Auth: secret\r\n" ++
            "\r\n";
        try sw.interface.writeAll(req);
        try sw.interface.flush();

        const expected =
            "HTTP/1.1 101 Switching Protocols\r\n" ++
            "connection: Upgrade\r\n" ++
            "upgrade: websocket\r\n" ++
            "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "\r\n";
        var got: [expected.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(expected, got[0..]);

        group.cancel(io);
        group.await(io) catch {};
        return;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var server = try Server.init(init.gpa, init.io, addr, {});
    defer server.deinit();

    std.debug.print("listening on http://127.0.0.1:{d}\n", .{port});
    std.debug.print("websocket endpoint: ws://127.0.0.1:{d}/ws (x-auth: secret)\n", .{port});
    try server.run();
}
