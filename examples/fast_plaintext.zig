const std = @import("std");
const zhttp = @import("zhttp");

fn usage() void {
    std.debug.print(
        \\fast_plaintext
        \\
        \\Usage:
        \\  zig build examples && ./zig-out/bin/zhttp-example-fast_plaintext --port=8080
        \\  zig build examples-check  # runs `--smoke`
        \\
        \\Options:
        \\  --port=8080
        \\  --smoke
        \\  --help
        \\
        \\Endpoints:
        \\  GET /plaintext
        \\
    , .{});
}

fn parseKeyVal(arg: []const u8) ?struct { key: []const u8, val: []const u8 } {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    return .{ .key = arg[2..eq], .val = arg[eq + 1 ..] };
}

fn plaintext() !zhttp.Res {
    return .{
        .status = 200,
        .headers = &.{
            .{ .name = "Server", .value = "zhttp" },
            .{ .name = "Content-Type", .value = "text/plain" },
        },
        .body = "Hello, World!",
    };
}

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
        if (parseKeyVal(arg)) |kv| {
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
            zhttp.get("/plaintext", plaintext, .{}),
        },
        .config = .{
            .fast_benchmark = true,
            .fast_benchmark_empty_headers = false,
        },
    });

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
        var stream = try std.Io.net.IpAddress.connect(addr, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [4 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        const req = "GET /plaintext HTTP/1.1\r\nHost: x\r\n\r\n";
        try sw.interface.writeAll(req);
        try sw.interface.flush();

        const resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "Server: zhttp\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "content-length: 13\r\n" ++
            "\r\n" ++
            "Hello, World!";

        var got: [resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(resp, got[0..]);

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
