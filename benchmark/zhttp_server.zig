const std = @import("std");
const zhttp = @import("zhttp");

fn plaintext() !zhttp.Res {
    const body = "Hello, World!";
    return .{
        .status = 200,
        .headers = &.{
            .{ .name = "Server", .value = "F" },
            .{ .name = "Content-Type", .value = "text/plain" },
            .{ .name = "Date", .value = "Wed, 24 Feb 2021 12:00:00 GMT" },
        },
        .body = body,
    };
}

fn usage() void {
    std.debug.print(
        \\zhttp-bench-server
        \\
        \\Usage:
        \\  zhttp-bench-server [--port=8081]
        \\
    , .{});
}

fn parseKeyVal(arg: []const u8) ?struct { key: []const u8, val: []const u8 } {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return null;
    return .{ .key = arg[2..eq], .val = arg[eq + 1 ..] };
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8081;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next(); // argv[0]

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
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
        .config = .{},
    });

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var server = try SrvT.init(init.gpa, init.io, addr, {});
    defer server.deinit();
    try server.run();
}
