const std = @import("std");
const zhttp = @import("zhttp");
const zws = @import("zwebsocket");
const ws = @import("zhttp_ws_support");

const Io = std.Io;

const StressRunner = ws.WsRunnerWith(.{
    .idle_timeout = .{
        .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(250),
            .clock = .awake,
        },
    },
    .socket_send_buffer_len = 1024,
    .socket_recv_buffer_len = 1024,
});

const StressServerT = zhttp.Server(.{
    .routes = .{
        zhttp.get("/ws", ws.upgrade, .{
            .headers = ws.WsHeaders,
            .middlewares = .{ws.Auth},
            .upgrade = StressRunner,
        }),
    },
});

const Config = struct {
    clients: usize = 128,
    rounds: usize = 8,
    messages: usize = 8,
};

const Counters = struct {
    ok: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    abrupt: std.atomic.Value(u64) = .init(0),
    idle: std.atomic.Value(u64) = .init(0),
    slow: std.atomic.Value(u64) = .init(0),
};

const ClientCtx = struct {
    io: Io,
    addr: std.Io.net.IpAddress,
    id: usize,
    config: Config,
    counters: *Counters,
};

fn shortSleep(io: Io, ms: i64) Io.Cancelable!void {
    return io.sleep(std.Io.Duration.fromMilliseconds(ms), .awake);
}

fn runClient(ctx: ClientCtx) Io.Cancelable!void {
    clientMain(ctx) catch {
        _ = ctx.counters.failed.fetchAdd(1, .monotonic);
        return;
    };
    _ = ctx.counters.ok.fetchAdd(1, .monotonic);
}

fn clientMain(ctx: ClientCtx) !void {
    for (0..ctx.config.rounds) |round| {
        var stream = try std.Io.net.IpAddress.connect(&ctx.addr, ctx.io, .{ .mode = .stream });
        var close_stream = true;
        defer if (close_stream) stream.close(ctx.io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [4 * 1024]u8 = undefined;
        var sr = stream.reader(ctx.io, &rb);
        var sw = stream.writer(ctx.io, &wb);

        const key = "dGhlIHNhbXBsZSBub25jZQ==";
        const req =
            "GET /ws HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
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
        switch ((ctx.id + round) % 4) {
            0 => try runNormalClient(&conn, ctx.config.messages),
            1 => try runIdleClient(ctx.io, &conn, ctx.counters),
            2 => {
                _ = ctx.counters.abrupt.fetchAdd(1, .monotonic);
                try runAbruptClient(ctx.io, &conn, &stream);
                close_stream = false;
            },
            3 => {
                _ = ctx.counters.slow.fetchAdd(1, .monotonic);
                try runSlowReaderClient(ctx.io, &conn, ctx.config.messages);
            },
            else => unreachable,
        }
    }
}

fn runNormalClient(conn: *zws.ClientConn, messages: usize) !void {
    var frame_buf: [512]u8 = undefined;
    var expected_buf: [96]u8 = undefined;

    for (0..messages) |i| {
        if (i % 3 == 0) try conn.writePing("k");
        var payload_buf: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&payload_buf, "msg-{d}", .{i});
        try conn.writeText(payload);
        try conn.flush();

        if (i % 3 == 0) {
            const pong = try conn.readFrame(frame_buf[0..]);
            if (pong.header.opcode != .pong) return error.BadPong;
            if (!std.mem.eql(u8, pong.payload, "k")) return error.BadPong;
        }

        const frame = try conn.readFrame(frame_buf[0..]);
        if (frame.header.opcode != .text) return error.BadEcho;
        const expected = try std.fmt.bufPrint(&expected_buf, "user-7: {s}", .{payload});
        if (!std.mem.eql(u8, expected, frame.payload)) return error.BadEcho;
    }

    try conn.writeClose(1000, "done");
    try conn.flush();
    const close_frame = try conn.readFrame(frame_buf[0..]);
    if (close_frame.header.opcode != .close) return error.BadClose;
}

fn runIdleClient(io: Io, conn: *zws.ClientConn, counters: *Counters) !void {
    _ = counters.idle.fetchAdd(1, .monotonic);
    try shortSleep(io, 400);
    var frame_buf: [128]u8 = undefined;
    _ = conn.readFrame(frame_buf[0..]) catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };
    return error.ExpectedEndOfStream;
}

fn runAbruptClient(io: Io, conn: *zws.ClientConn, stream: *std.Io.net.Stream) !void {
    try conn.writeText("bye");
    try conn.flush();
    stream.close(io);
}

fn runSlowReaderClient(io: Io, conn: *zws.ClientConn, messages: usize) !void {
    var payload: [128]u8 = [_]u8{'x'} ** 128;
    for (0..messages * 16) |_| {
        try conn.writeText(payload[0..]);
    }
    try conn.flush();
    try shortSleep(io, 500);
}

fn parseArgs(init: std.process.Init) !Config {
    var cfg: Config = .{};
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\websocket-stress
                \\
                \\Options:
                \\  --clients=128
                \\  --rounds=8
                \\  --messages=8
                \\
            , .{});
            std.process.exit(0);
        }
        if (!std.mem.startsWith(u8, arg, "--")) return error.UnknownArg;
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.UnknownArg;
        const key = arg[2..eq];
        const value = arg[eq + 1 ..];
        if (std.mem.eql(u8, key, "clients")) {
            cfg.clients = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, key, "rounds")) {
            cfg.rounds = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, key, "messages")) {
            cfg.messages = try std.fmt.parseInt(usize, value, 10);
        } else {
            return error.UnknownArg;
        }
    }

    return cfg;
}

pub fn main(init: std.process.Init) !void {
    const cfg = try parseArgs(init);

    var threaded = std.Io.Threaded.init(init.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try StressServerT.init(init.gpa, io, addr0, {});
    defer server.deinit();
    const port = server.listener.socket.address.getPort();
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };

    var server_group: Io.Group = .init;
    defer server_group.await(io) catch {};
    defer server_group.cancel(io);
    try server_group.concurrent(io, StressServerT.run, .{&server});

    var client_group: Io.Group = .init;
    defer client_group.await(io) catch {};
    defer client_group.cancel(io);

    var counters: Counters = .{};
    for (0..cfg.clients) |id| {
        try client_group.concurrent(io, runClient, .{ClientCtx{
            .io = io,
            .addr = addr,
            .id = id,
            .config = cfg,
            .counters = &counters,
        }});
    }

    try client_group.await(io);

    const ok = counters.ok.load(.acquire);
    const failed = counters.failed.load(.acquire);
    const abrupt = counters.abrupt.load(.acquire);
    const idle = counters.idle.load(.acquire);
    const slow = counters.slow.load(.acquire);

    std.debug.print(
        "websocket stress complete: ok={d} failed={d} abrupt={d} idle={d} slow={d}\n",
        .{ ok, failed, abrupt, idle, slow },
    );

    if (failed != 0) return error.StressFailed;
}
