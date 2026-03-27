const std = @import("std");
const zhttp = @import("zhttp");
const zws = @import("zwebsocket");
const ws = @import("zhttp_ws_support");
const scripts = @import("scripts.zig");

const Res = zhttp.Res;

const Runner = ws.WsRunnerWith(.{});

const SoakHeaders = struct {
    connection: zhttp.parse.Optional(zhttp.parse.String),
    upgrade: zhttp.parse.Optional(zhttp.parse.String),
    sec_websocket_key: zhttp.parse.Optional(zhttp.parse.String),
    sec_websocket_version: zhttp.parse.Optional(zhttp.parse.String),
    sec_websocket_protocol: zhttp.parse.Optional(zhttp.parse.String),
    sec_websocket_extensions: zhttp.parse.Optional(zhttp.parse.String),
    origin: zhttp.parse.Optional(zhttp.parse.String),
    host: zhttp.parse.Optional(zhttp.parse.String),
};

const SoakServerT = zhttp.Server(.{
    .routes = .{
        zhttp.get("/ws", upgrade, .{
            .headers = SoakHeaders,
            .upgrade = Runner,
        }),
    },
});

fn usage() void {
    std.debug.print(
        \\websocket-soak-server
        \\
        \\Usage:
        \\  ./zig-out/bin/zhttp-websocket-soak-server --port=19090
        \\
    , .{});
}

fn upgrade(req: anytype) !Res {
    const hs = zws.acceptZhttpUpgrade(req, .{}) catch return Res.text(400, "bad websocket handshake\n");
    return ws.makeUpgradeResponse(req, hs);
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 19090;

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();

    while (it.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        }
        if (scripts.parseKeyVal(arg)) |kv| {
            if (std.mem.eql(u8, kv.key, "port")) {
                port = try std.fmt.parseInt(u16, kv.val, 10);
            } else {
                return error.UnknownArg;
            }
            continue;
        }
        return error.UnknownArg;
    }

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var server = try SoakServerT.init(init.gpa, init.io, addr, {});
    defer server.deinit();

    std.debug.print("websocket soak server listening on ws://127.0.0.1:{d}/ws\n", .{port});
    try server.run();
}
