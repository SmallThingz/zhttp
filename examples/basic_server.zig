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

const Health = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};
    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        _ = req;
        return zhttp.Res.text(200, "ok");
    }
};

const Hello = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .query = struct {
            name: zhttp.parse.Optional(zhttp.parse.String),
        },
    };
    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const name_opt = req.queryParam(.name) orelse "world";
        const body = try std.fmt.allocPrint(req.allocator(), "hello {s}\n", .{name_opt});
        return zhttp.Res.text(200, body);
    }
};

const User = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .headers = struct {
            host: zhttp.parse.Optional(zhttp.parse.String),
        },
        .path = struct {
            id: zhttp.parse.Int(u64),
        },
    };
    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const id = req.paramValue(.id);
        const host = req.header(.host) orelse "(no host)";
        const body = try std.fmt.allocPrint(req.allocator(), "id={d} host={s}\n", .{ id, host });
        return zhttp.Res.text(200, body);
    }
};

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

    const SrvT = zhttp.Server(.{
        .routes = .{
            zhttp.get("/health", Health),
            zhttp.get("/hello", Hello),
            zhttp.get("/users/{id}", User),
        },
    });

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
