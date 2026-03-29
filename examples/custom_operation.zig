const std = @import("std");
const zhttp = @import("zhttp");
const common = @import("common.zig");
const ReqCtx = zhttp.ReqCtx;

fn usage() void {
    std.debug.print(
        \\custom_operation
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-custom_operation --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
        \\Endpoints:
        \\  GET /admin
        \\  GET /widgets/{{id}}
        \\  GET /__routes   (added by custom operation)
        \\
    , .{});
}

const RoutesIndex = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const route_count = req.server().routeDecls().len;
        const body = try std.fmt.allocPrint(req.allocator(), "routes={d}\n", .{route_count});
        return zhttp.Res.text(200, body);
    }
};

const AddRoutes = struct {
    pub fn maxAddedRoutes(comptime _: usize) usize {
        return 1;
    }

    pub fn operation(comptime opctx: zhttp.operations.OperationCtx, r: opctx.T()) void {
        if (opctx.filter(r).len == 0) return;
        if (!r.hasMethodPath("GET", "/__routes")) {
            r.add(zhttp.get("/__routes", RoutesIndex));
        }
    }
};

const Admin = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .operations = &.{AddRoutes},
    };

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        _ = req;
        return zhttp.Res.text(200, "admin\n");
    }
};

const Widget = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .path = struct {
            id: zhttp.parse.Int(u32),
        },
    };

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        const body = try std.fmt.allocPrint(req.allocator(), "widget {d}\n", .{req.paramValue(.id)});
        return zhttp.Res.text(200, body);
    }
};

const SrvT = zhttp.Server(.{
    .operations = .{
        AddRoutes,
    },
    .routes = .{
        zhttp.get("/admin", Admin),
        zhttp.get("/widgets/{id}", Widget),
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
        var server = try SrvT.init(init.gpa, io, addr0, {});
        defer server.deinit();
        const actual_port: u16 = server.listener.socket.address.getPort();

        var group: std.Io.Group = .init;
        var group_done = false;
        defer if (!group_done) {
            group.cancel(io);
            group.await(io) catch {};
        };
        try group.concurrent(io, SrvT.run, .{&server});

        const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(actual_port) };
        var stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        var close_stream = true;
        defer if (close_stream) stream.close(io);

        var rb: [8 * 1024]u8 = undefined;
        var wb: [8 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        const req =
            "GET /admin HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /widgets/7 HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /__routes HTTP/1.1\r\nHost: x\r\n\r\n";
        try sw.interface.writeAll(req);
        try sw.interface.flush();

        const admin_resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 6\r\n" ++
            "\r\n" ++
            "admin\n";
        const widget_resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 9\r\n" ++
            "\r\n" ++
            "widget 7\n";
        const routes_resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 9\r\n" ++
            "\r\n" ++
            "routes=3\n";

        var got_admin: [admin_resp.len]u8 = undefined;
        var got_widget: [widget_resp.len]u8 = undefined;
        var got_routes: [routes_resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got_admin[0..]);
        try sr.interface.readSliceAll(got_widget[0..]);
        try sr.interface.readSliceAll(got_routes[0..]);
        try std.testing.expectEqualStrings(admin_resp, got_admin[0..]);
        try std.testing.expectEqualStrings(widget_resp, got_widget[0..]);
        try std.testing.expectEqualStrings(routes_resp, got_routes[0..]);

        stream.close(io);
        close_stream = false;
        group.cancel(io);
        group.await(io) catch {};
        group_done = true;
        return;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var server = try SrvT.init(init.gpa, init.io, addr, {});
    defer server.deinit();

    std.debug.print("listening on http://127.0.0.1:{d}\n", .{port});
    try server.run();
}
