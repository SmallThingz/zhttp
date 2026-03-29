const std = @import("std");
const zhttp = @import("zhttp");
const common = @import("common.zig");
const ReqCtx = zhttp.ReqCtx;

fn usage() void {
    std.debug.print(
        \\response_modes
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-response_modes --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
        \\Endpoints:
        \\  GET /plain    -> []const u8 body
        \\  GET /parts    -> [][]const u8 body
        \\  GET /stream   -> chunked custom body
        \\
    , .{});
}

const Plain = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        _ = req;
        return zhttp.Res.text(200, "plain\n");
    }
};

const segmented_parts = [_][]const u8{
    "segment",
    "-",
    "body",
    "\n",
};

const Parts = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response([][]const u8) {
        _ = req;
        const body: [][]const u8 = @constCast(segmented_parts[0..]);
        return .{
            .status = .ok,
            .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            .body = body,
        };
    }
};

const Stream = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    const Body = struct {
        pub fn body(_: @This(), comptime rctx: ReqCtx, req: rctx.TReadOnly(), cw: *zhttp.response.ChunkedWriter) std.Io.Writer.Error!void {
            _ = req;
            try cw.writeAll("chunk-");
            try cw.writeAll("stream\n");
        }
    };

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response(Body) {
        _ = req;
        return .{
            .status = .ok,
            .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            .body = .{},
        };
    }
};

const SrvT = zhttp.Server(.{
    .routes = .{
        zhttp.get("/plain", Plain),
        zhttp.get("/parts", Parts),
        zhttp.get("/stream", Stream),
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
        defer group.cancel(io);
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
            "GET /plain HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /parts HTTP/1.1\r\nHost: x\r\n\r\n" ++
            "GET /stream HTTP/1.1\r\nHost: x\r\n\r\n";
        try sw.interface.writeAll(req);
        try sw.interface.flush();

        const plain_resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 6\r\n" ++
            "\r\n" ++
            "plain\n";
        const parts_resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 13\r\n" ++
            "\r\n" ++
            "segment-body\n";
        const stream_resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "transfer-encoding: chunked\r\n" ++
            "\r\n" ++
            "6\r\n" ++
            "chunk-\r\n" ++
            "7\r\n" ++
            "stream\n\r\n" ++
            "0\r\n\r\n";

        var got_plain: [plain_resp.len]u8 = undefined;
        var got_parts: [parts_resp.len]u8 = undefined;
        var got_stream: [stream_resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got_plain[0..]);
        try sr.interface.readSliceAll(got_parts[0..]);
        try sr.interface.readSliceAll(got_stream[0..]);
        try std.testing.expectEqualStrings(plain_resp, got_plain[0..]);
        try std.testing.expectEqualStrings(parts_resp, got_parts[0..]);
        try std.testing.expectEqualStrings(stream_resp, got_stream[0..]);

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
