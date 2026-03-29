const std = @import("std");
const zhttp = @import("zhttp");
const common = @import("common.zig");
const ReqCtx = zhttp.ReqCtx;

fn usage() void {
    std.debug.print(
        \\route_static_access
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-route_static_access --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
        \\Endpoints:
        \\  GET /touch   # increments /state static counter
        \\  GET /state   # shows route-local static state
        \\
    , .{});
}

const RouteStaticCtx = struct {
    pattern: []const u8,
    touched: usize = 0,

    pub fn init(_: std.Io, _: std.mem.Allocator, route_decl: zhttp.router.RouteDecl) @This() {
        return .{
            .pattern = route_decl.pattern,
        };
    }
};

const RouteStaticMw = struct {
    pub const Info: zhttp.middleware.MiddlewareInfo = .{
        .name = "route_static",
        .static_context = RouteStaticCtx,
    };

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        return rctx.next(req);
    }
};

const Touch = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .middlewares = &.{RouteStaticMw},
    };

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const ServerT = rctx.Server();
        const state_idx = comptime ServerT.routeIndex("GET", "/state");
        const state_static = req.server().routeStatic(state_idx);
        state_static.route_static.touched += 1;
        return zhttp.Res.text(200, "touched");
    }
};

const State = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .middlewares = &.{RouteStaticMw},
    };

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const me = req.middlewareStaticConst(.route_static);
        const body = try std.fmt.allocPrint(req.allocator(), "{s}:{d}", .{ me.pattern, me.touched });
        return zhttp.Res.text(200, body);
    }
};

const SrvT = zhttp.Server(.{
    .routes = .{
        zhttp.get("/touch", Touch),
        zhttp.get("/state", State),
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
        var close_stream = true;
        defer if (close_stream) stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [4 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        try sw.interface.writeAll("GET /state HTTP/1.1\r\nHost: x\r\n\r\n");
        try sw.interface.flush();
        const state0 =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 8\r\n" ++
            "\r\n" ++
            "/state:0";
        var got0: [state0.len]u8 = undefined;
        try sr.interface.readSliceAll(got0[0..]);
        try std.testing.expectEqualStrings(state0, got0[0..]);

        try sw.interface.writeAll("GET /touch HTTP/1.1\r\nHost: x\r\n\r\n");
        try sw.interface.flush();
        const touched =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 7\r\n" ++
            "\r\n" ++
            "touched";
        var got1: [touched.len]u8 = undefined;
        try sr.interface.readSliceAll(got1[0..]);
        try std.testing.expectEqualStrings(touched, got1[0..]);

        try sw.interface.writeAll("GET /state HTTP/1.1\r\nHost: x\r\n\r\n");
        try sw.interface.flush();
        const state1 =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 8\r\n" ++
            "\r\n" ++
            "/state:1";
        var got2: [state1.len]u8 = undefined;
        try sr.interface.readSliceAll(got2[0..]);
        try std.testing.expectEqualStrings(state1, got2[0..]);

        stream.close(io);
        close_stream = false;
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
