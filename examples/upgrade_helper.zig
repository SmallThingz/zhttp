const std = @import("std");
const zhttp = @import("zhttp");
const common = @import("common.zig");
const ReqCtx = zhttp.ReqCtx;

const Io = std.Io;

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

fn usage() void {
    std.debug.print(
        \\upgrade_helper
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-upgrade_helper --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
        \\Endpoint:
        \\  GET /up   (requires `upgrade: chat`, `connection: Upgrade`, `x-auth: secret`)
        \\
        \\Notes:
        \\  - Uses `zhttp.upgrade.responseFor(...)` to build the 101 response.
        \\
    , .{});
}

const UpgradeHeaders = struct {
    /// Stores `connection`.
    connection: zhttp.parse.Optional(zhttp.parse.String),
    /// Stores `upgrade`.
    upgrade: zhttp.parse.Optional(zhttp.parse.String),
    /// Stores `x_auth`.
    x_auth: zhttp.parse.Optional(zhttp.parse.String),
};

const UpgradeHandshake = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .headers = UpgradeHeaders,
    };
    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const auth = req.header(.x_auth) orelse return zhttp.Res.text(401, "missing x-auth\n");
        if (!std.mem.eql(u8, auth, "secret")) return zhttp.Res.text(403, "bad x-auth\n");

        const connection = req.header(.connection) orelse return zhttp.Res.text(400, "missing connection\n");
        if (!std.ascii.eqlIgnoreCase(connection, "Upgrade")) {
            return zhttp.Res.text(400, "expected connection: Upgrade\n");
        }

        const upgrade_value = req.header(.upgrade) orelse return zhttp.Res.text(400, "missing upgrade\n");
        if (!std.ascii.eqlIgnoreCase(upgrade_value, "chat")) {
            return .{
                .status = @enumFromInt(426),
                .headers = &.{.{ .name = "upgrade", .value = "chat" }},
                .body = "unsupported upgrade protocol\n",
            };
        }

        const extra = [_]zhttp.response.Header{
            .{ .name = "x-upgrade-helper", .value = "1" },
        };
        return zhttp.upgrade.responseFor(req.allocator(), .{
            .protocol = "chat",
            .extra_headers = extra[0..],
        });
    }

    pub fn upgrade(
        server: *SrvT,
        stream: *const std.Io.net.Stream,
        r: *Io.Reader,
        w: *Io.Writer,
        line: zhttp.request.RequestLine,
        res: zhttp.Res,
    ) void {
        return onUpgrade(server, stream, r, w, line, res);
    }
};

fn onUpgrade(
    server: *SrvT,
    stream: *const std.Io.net.Stream,
    _: *Io.Reader,
    w: *Io.Writer,
    _: zhttp.request.RequestLine,
    _: zhttp.Res,
) void {
    defer stream.close(server.io);
    w.writeAll("WELCOME\n") catch return;
    w.flush() catch return;
}

const SrvT = zhttp.Server(.{
    .routes = .{
        zhttp.get("/up", UpgradeHandshake),
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
            "GET /up HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: chat\r\n" ++
            "X-Auth: secret\r\n" ++
            "\r\n";
        try sw.interface.writeAll(req);
        try sw.interface.flush();

        const expected =
            "HTTP/1.1 101 Switching Protocols\r\n" ++
            "connection: Upgrade\r\n" ++
            "upgrade: chat\r\n" ++
            "x-upgrade-helper: 1\r\n" ++
            "\r\n";
        var got: [expected.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(expected, got[0..]);

        var welcome: [8]u8 = undefined;
        try sr.interface.readSliceAll(welcome[0..]);
        try std.testing.expectEqualStrings("WELCOME\n", welcome[0..]);

        stream.close(io);
        close_stream = false;
        group.cancel(io);
        group.await(io) catch {};
        group_done = true;
        return;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    std.debug.print("upgrade endpoint: http://127.0.0.1:{d}/up (x-auth: secret)\n", .{port});
    try SrvT.run(.{
        .gpa = init.gpa,
        .io = init.io,
        .address = addr,
        .ctx = {},
    });
}
