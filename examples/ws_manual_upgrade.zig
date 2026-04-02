const std = @import("std");
const zhttp = @import("zhttp");
const zws = @import("zws");
const common = @import("common.zig");
const ReqCtx = zhttp.ReqCtx;

const Io = std.Io;

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

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
        \\  - `zhttp.upgrade.acceptWebSocket(...)` validates the HTTP handshake.
        \\  - `zhttp.upgrade.rejectWebSocket(...)` maps handshake errors to HTTP responses.
        \\  - endpoint `upgrade(...)` owns upgraded connection lifecycle.
        \\
    , .{});
}

const WsHeaders = zhttp.parse.mergeHeaderStructs(zhttp.upgrade.WebSocketHeaders, struct {
    x_auth: zhttp.parse.Optional(zhttp.parse.String),
});

const Handshake = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .headers = WsHeaders,
    };
    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const auth = req.header(.x_auth) orelse return zhttp.Res.text(401, "missing x-auth\n");
        if (!std.mem.eql(u8, auth, "secret")) return zhttp.Res.text(403, "bad x-auth\n");
        return zhttp.upgrade.acceptWebSocket(req, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return zhttp.upgrade.rejectWebSocket(err),
        };
    }

    pub fn upgrade(
        server: *Server,
        stream: *const std.Io.net.Stream,
        r: *Io.Reader,
        w: *Io.Writer,
        line: zhttp.request.RequestLine,
        res: zhttp.Res,
    ) void {
        return onUpgrade(server, stream, r, w, line, res);
    }
};

fn closeForProtocolError(conn: *zws.Conn.Server, w: *Io.Writer, err: anyerror) void {
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
    server: *Server,
    stream: *const std.Io.net.Stream,
    r: *Io.Reader,
    w: *Io.Writer,
    _: zhttp.request.RequestLine,
    _: zhttp.Res,
) void {
    defer stream.close(server.io);

    var conn = zws.Conn.Server.init(r, w, .{
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
        zhttp.get("/ws", Handshake),
    },
});

fn runServer(args: Server.RunArgs) std.Io.Cancelable!void {
    Server.run(args) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => @panic(@errorName(err)),
    };
}

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
        const io = init.io;

        const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
        var actual_port: u16 = 0;

        var group: std.Io.Group = .init;
        var group_done = false;
        defer if (!group_done) {
            group.cancel(io);
            group.await(io) catch {};
        };
        try group.concurrent(io, runServer, .{.{
            .gpa = init.gpa,
            .io = io,
            .address = addr0,
            .ctx = {},
            .actual_port_out = &actual_port,
        }});
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

        // Smoke keeps the flow on plain HTTP (no upgrade) so cancellation remains deterministic.
        const req =
            "GET /ws HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Connection: close\r\n" ++
            "\r\n";
        try sw.interface.writeAll(req);
        try sw.interface.flush();

        const expected = "HTTP/1.1 401";
        var got: [expected.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(expected, got[0..]);

        stream.close(io);
        close_stream = false;
        group.cancel(io);
        group.await(io) catch {};
        group_done = true;
        return;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    std.debug.print("listening on http://127.0.0.1:{d}\n", .{port});
    std.debug.print("websocket endpoint: ws://127.0.0.1:{d}/ws (x-auth: secret)\n", .{port});
    try Server.run(.{ .gpa = init.gpa, .io = init.io, .address = addr, .ctx = {} });
}
