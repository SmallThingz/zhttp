const std = @import("std");
const zhttp = @import("zhttp");
const common = @import("common.zig");
const ReqCtx = zhttp.ReqCtx;

fn usage() void {
    std.debug.print(
        \\compression_negotiation
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-compression_negotiation --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
        \\Endpoints:
        \\  GET /blob
        \\
        \\Notes:
        \\  - Shows best-effort compression with whitelist order.
        \\  - This example allows only gzip/deflate.
        \\
    , .{});
}

fn readResponse(r: *std.Io.Reader, allocator: std.mem.Allocator) !struct { head: []u8, body: []u8 } {
    var header_buf: std.ArrayList(u8) = .empty;
    errdefer header_buf.deinit(allocator);
    while (true) {
        const line_incl = try r.takeDelimiterInclusive('\n');
        try header_buf.appendSlice(allocator, line_incl);
        const line = line_incl[0 .. line_incl.len - 1];
        if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
    }
    const header = try header_buf.toOwnedSlice(allocator);
    const idx = std.mem.indexOf(u8, header, "content-length:") orelse return error.BadResponse;
    const line_end = std.mem.indexOfScalarPos(u8, header, idx, '\n') orelse return error.BadResponse;
    const len_line = std.mem.trim(u8, header[idx + "content-length:".len .. line_end], " \t\r");
    const len = try std.fmt.parseInt(usize, len_line, 10);
    const body = try allocator.alloc(u8, len);
    try r.readSliceAll(body);
    return .{ .head = header, .body = body };
}

fn headerContains(head: []const u8, allocator: std.mem.Allocator, needle_lower: []const u8) !bool {
    const lower = try std.ascii.allocLowerString(allocator, head);
    defer allocator.free(lower);
    return std.mem.indexOf(u8, lower, needle_lower) != null;
}

const blob =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" ++
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";

const Blob = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !zhttp.Res {
        _ = req;
        return zhttp.Res.text(200, blob);
    }
};

const SrvT = zhttp.Server(.{
    .middlewares = .{
        zhttp.middleware.Compression(.{
            .schemes = &.{ .gzip, .deflate },
            .min_size = 1,
        }),
    },
    .routes = .{
        zhttp.get("/blob", Blob),
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

        {
            const req =
                "GET /blob HTTP/1.1\r\n" ++
                "Host: x\r\n" ++
                "Accept-Encoding: br, gzip;q=0.9, deflate;q=0.8\r\n" ++
                "\r\n";
            try sw.interface.writeAll(req);
            try sw.interface.flush();
            const resp = try readResponse(&sr.interface, init.gpa);
            defer init.gpa.free(resp.head);
            defer init.gpa.free(resp.body);
            try std.testing.expect(try headerContains(resp.head, init.gpa, "content-encoding: gzip"));
            try std.testing.expect(try headerContains(resp.head, init.gpa, "vary: accept-encoding"));
            try std.testing.expect(resp.body.len != 0);
        }

        {
            const req =
                "GET /blob HTTP/1.1\r\n" ++
                "Host: x\r\n" ++
                "Accept-Encoding: deflate;q=1.0, gzip;q=0.1\r\n" ++
                "\r\n";
            try sw.interface.writeAll(req);
            try sw.interface.flush();
            const resp = try readResponse(&sr.interface, init.gpa);
            defer init.gpa.free(resp.head);
            defer init.gpa.free(resp.body);
            try std.testing.expect(try headerContains(resp.head, init.gpa, "content-encoding: deflate"));
            try std.testing.expect(try headerContains(resp.head, init.gpa, "vary: accept-encoding"));
            try std.testing.expect(resp.body.len != 0);
        }

        {
            const req =
                "GET /blob HTTP/1.1\r\n" ++
                "Host: x\r\n" ++
                "\r\n";
            try sw.interface.writeAll(req);
            try sw.interface.flush();
            const resp = try readResponse(&sr.interface, init.gpa);
            defer init.gpa.free(resp.head);
            defer init.gpa.free(resp.body);
            try std.testing.expect(!try headerContains(resp.head, init.gpa, "content-encoding:"));
            try std.testing.expectEqualStrings(blob, resp.body);
        }

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
