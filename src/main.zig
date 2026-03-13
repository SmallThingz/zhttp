const std = @import("std");
const zhttp = @import("zhttp");

const App = struct {
    greeting: []const u8 = "hello",
};

const RequireHost = struct {
    pub const Needs = struct {
        headers: type = struct {
            host: zhttp.parse.Optional(zhttp.parse.String),
        },
        query: type = struct {},
    };

    pub fn call(comptime Next: type, next: Next, app: *App, req: anytype) !zhttp.Res {
        if (req.header(.host) == null) {
            return zhttp.Res.text(400, "missing host\n");
        }
        return try next.call(app, req);
    }
};

fn hello(app: *App, req: anytype) !zhttp.Res {
    const name = req.queryParam(.name) orelse "world";
    const body = try std.fmt.allocPrint(req.allocator(), "{s} {s}\n", .{ app.greeting, name });
    return .{
        .status = 200,
        .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        .body = body,
    };
}

fn user(app: *App, req: anytype) !zhttp.Res {
    _ = app;
    const id = req.param(.id);
    const body = try std.fmt.allocPrint(req.allocator(), "user {s}\n", .{id});
    return zhttp.Res.text(200, body);
}

pub fn main(init: std.process.Init) !void {
    var app: App = .{};

    const SrvT = zhttp.Server(.{
        .Context = App,
        .middlewares = .{RequireHost},
        .routes = .{
            zhttp.get("/", .{
                .query = struct {
                    name: zhttp.parse.Optional(zhttp.parse.String),
                },
            }, hello),
            zhttp.get("/users/{id}", .{}, user),
        },
        .config = .{
            .read_buffer = 32 * 1024,
            .write_buffer = 16 * 1024,
            .max_request_line = 8 * 1024,
            .max_header_bytes = 32 * 1024,
        },
    });

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(3000) };
    var server = try SrvT.init(init.gpa, init.io, addr, &app);
    defer server.deinit();

    try server.run();
}
