const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const response = @import("response.zig");
const request = @import("request.zig");
const router = @import("router.zig");

fn setTcpNoDelay(stream: *const std.Io.net.Stream) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    var one: i32 = 1;
    std.posix.setsockopt(
        stream.socket.handle,
        @intCast(linux.IPPROTO.TCP),
        linux.TCP.NODELAY,
        std.mem.asBytes(&one),
    ) catch {};
}

pub const Config = struct {
    /// Per-connection read buffer size.
    read_buffer: usize = 8 * 1024,
    /// Per-connection write buffer size. Zero disables buffering.
    write_buffer: usize = 0,
    /// Enable TCP_NODELAY (disables Nagle). Off by default.
    tcp_nodelay: bool = false,
    /// Maximum request line length (bytes, including `\r\n`).
    max_request_line: usize = 8 * 1024,
    /// Maximum total header bytes (bytes, including line endings).
    max_header_bytes: usize = 32 * 1024,
};

fn configField(comptime cfg: anytype, comptime name: []const u8, default: anytype) @TypeOf(default) {
    if (@hasField(@TypeOf(cfg), name)) return @field(cfg, name);
    return default;
}

/// Server definition options (`def`) are provided at comptime.
///
/// Supported fields:
/// - `Context: type`      Optional user context type. Defaults to `void`.
/// - `middlewares: tuple` Optional global middleware types. Defaults to `.{}`.
/// - `routes: struct`     Required routes tuple/struct: `.{ zhttp.get(...), ... }`.
/// - `config: struct`     Optional config overrides (fields match `zhttp.server.Config`).
pub fn Server(comptime def: anytype) type {
    if (!@hasField(@TypeOf(def), "routes")) @compileError("Server definition must include `.routes = .{ ... }`");
    const Context = if (@hasField(@TypeOf(def), "Context")) def.Context else void;
    const Middlewares = if (@hasField(@TypeOf(def), "middlewares")) def.middlewares else .{};
    const MiddlewareRoutes = router.middlewareRoutes(Middlewares);
    const Routes = router.mergeRoutes(def.routes, MiddlewareRoutes);
    const cfg = if (@hasField(@TypeOf(def), "config")) def.config else .{};

    const defaults: Config = .{};
    const Conf: Config = .{
        .read_buffer = configField(cfg, "read_buffer", defaults.read_buffer),
        .write_buffer = configField(cfg, "write_buffer", defaults.write_buffer),
        .tcp_nodelay = configField(cfg, "tcp_nodelay", defaults.tcp_nodelay),
        .max_request_line = configField(cfg, "max_request_line", defaults.max_request_line),
        .max_header_bytes = configField(cfg, "max_header_bytes", defaults.max_header_bytes),
    };

    const ErrorHandler = if (@hasField(@TypeOf(def), "error_handler")) def.error_handler else null;
    const Compiled = router.Compiled(Context, Routes, Middlewares, ErrorHandler);
    const EmptyMwCtx = struct {};
    const EmptyReq = request.Request(struct {}, struct {}, &.{}, EmptyMwCtx);

    return struct {
        io: Io,
        gpa: Allocator,
        listener: std.Io.net.Server,
        group: Io.Group = .init,
        ctx: if (Context == void) void else *Context,

        const Self = @This();

        pub fn init(
            gpa: Allocator,
            io: Io,
            address: std.Io.net.IpAddress,
            ctx: if (Context == void) void else *Context,
        ) !Self {
            const listener = try std.Io.net.IpAddress.listen(address, io, .{ .reuse_address = true });
            return .{
                .io = io,
                .gpa = gpa,
                .listener = listener,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.listener.deinit(self.io);
            self.group.cancel(self.io);
            self.* = undefined;
        }

        pub fn run(self: *Self) Io.Cancelable!void {
            while (true) {
                const stream = self.listener.accept(self.io) catch |err| switch (err) {
                    error.SocketNotListening => return,
                    error.Canceled => return error.Canceled,
                    else => return,
                };
                self.group.concurrent(self.io, handleConn, .{ self, stream }) catch {
                    stream.close(self.io);
                };
            }
        }

        fn writeSimple(self: *Self, w: *Io.Writer, status: u16, body: []const u8) void {
            const res = response.Res.text(status, body);
            response.write(w, res, false, true) catch {};
            w.flush() catch {};
            _ = self;
        }

        fn handleConn(self: *Self, stream: std.Io.net.Stream) Io.Cancelable!void {
            defer stream.close(self.io);
            if (Conf.tcp_nodelay) setTcpNoDelay(&stream);

            var read_buf: [Conf.read_buffer]u8 = undefined;
            var write_buf: [Conf.write_buffer]u8 = undefined;

            var sr = stream.reader(self.io, &read_buf);
            var sw = stream.writer(self.io, &write_buf);

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();

            var params_buf: [Compiled.MaxParams][]u8 = undefined;

            while (true) {
                _ = arena.reset(.retain_capacity);
                const a = arena.allocator();

                const line = request.parseRequestLineBorrowed(&sr.interface, Conf.max_request_line) catch |err| switch (err) {
                    error.EndOfStream => return,
                    error.UriTooLong => {
                        writeSimple(self, &sw.interface, 414, "uri too long");
                        return;
                    },
                    else => {
                        writeSimple(self, &sw.interface, 400, "bad request");
                        return;
                    },
                };

                // Route on method + path first (no header parsing yet).
                const send_body = !(line.method.len == 4 and line.method[0] == 'H' and line.method[1] == 'E' and line.method[2] == 'A' and line.method[3] == 'D');
                const rid = Compiled.match(line.method, line.path, params_buf[0..Compiled.MaxParams]);

                var res: response.Res = undefined;
                var keep_alive: bool = false;

                if (rid) |route_index| {
                    const dr = Compiled.dispatch(
                        if (Context == void) {} else self.ctx,
                        self.io,
                        a,
                        &sr.interface,
                        line,
                        route_index,
                        params_buf[0..Compiled.MaxParams],
                        Conf.max_header_bytes,
                    ) catch |err| {
                        if (err == error.EndOfStream or err == error.ReadFailed) return;
                        const e: anyerror = err;
                        const status: u16 = switch (e) {
                            error.HeadersTooLarge => 431,
                            error.UriTooLong => 414,
                            error.PayloadTooLarge => 413,
                            error.MissingRequired,
                            error.BadValue,
                            error.InvalidPercentEncoding,
                            error.BadRequest,
                            => 400,
                            else => 500,
                        };
                        writeSimple(self, &sw.interface, status, if (status == 500) "internal error" else "bad request");
                        return;
                    };
                    res = dr.res;
                    keep_alive = dr.keep_alive;
                } else {
                    const mw_ctx: EmptyMwCtx = .{};
                    var reqv = EmptyReq.init(a, self.io, line, mw_ctx);
                    defer reqv.deinit(a);
                    reqv.parseHeaders(a, &sr.interface, Conf.max_header_bytes) catch |err| {
                        if (err == error.EndOfStream or err == error.ReadFailed) return;
                        const status: u16 = switch (err) {
                            error.HeadersTooLarge => 431,
                            else => 400,
                        };
                        writeSimple(self, &sw.interface, status, "bad request");
                        return;
                    };
                    reqv.discardUnreadBody() catch {
                        return;
                    };
                    keep_alive = reqv.keepAlive();
                    res = response.Res.text(404, "not found");
                }

                response.write(&sw.interface, res, keep_alive, send_body) catch {
                    return;
                };
                if (sw.interface.buffered().len != 0) {
                    sw.interface.flush() catch {
                        return;
                    };
                }

                if (!keep_alive or res.close) return;
            }
        }
    };
}

test "Connection: close header closes socket" {
    const Bench = struct {
        fn plaintext(_: void, _: anytype) !response.Res {
            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Server: F\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: 13\r\n" ++
                "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
                "\r\n" ++
                "Hello, World!";
            return response.Res.rawResponse(resp);
        }
    };

    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const SrvT = Server(.{
        .routes = .{
            router.get("/plaintext", Bench.plaintext, .{}),
        },
        .config = .{
            .read_buffer = 64 * 1024,
            .write_buffer = 16 * 1024,
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.init(std.testing.allocator, io, addr0, {});
    defer server.deinit();

    const port: u16 = server.listener.socket.address.getPort();
    try std.testing.expect(port != 0);

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, SrvT.run, .{&server});

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(addr, io, .{ .mode = .stream });
    defer stream.close(io);

    const req =
        "GET /plaintext HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "\r\n" ++
        "Hello, World!";
    const resp_len: usize = resp.len;

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll(req);
    try sw.interface.flush();

    var got: [resp_len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expect(std.mem.eql(u8, got[0..], resp));

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));

    group.cancel(io);
    group.await(io) catch {};
}

test "handler res.close closes socket" {
    const Handlers = struct {
        fn close_me(_: void, _: anytype) !response.Res {
            var r = response.Res.text(200, "bye");
            r.close = true;
            return r;
        }
    };

    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const SrvT = Server(.{
        .routes = .{
            router.get("/x", Handlers.close_me, .{}),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.init(std.testing.allocator, io, addr0, {});
    defer server.deinit();
    const port: u16 = server.listener.socket.address.getPort();

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, SrvT.run, .{&server});

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GET /x HTTP/1.1\r\nHost: x\r\n\r\n");
    try sw.interface.flush();

    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 3\r\n" ++
        "\r\n" ++
        "bye";
    var got: [resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(resp, got[0..]);

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));

    group.cancel(io);
    group.await(io) catch {};
}

test "HTTP/1.0 request does not keep-alive" {
    const Handlers = struct {
        fn ok() !response.Res {
            return response.Res.text(200, "ok");
        }
    };

    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const SrvT = Server(.{
        .routes = .{
            router.get("/x", Handlers.ok, .{}),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.init(std.testing.allocator, io, addr0, {});
    defer server.deinit();
    const port: u16 = server.listener.socket.address.getPort();

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, SrvT.run, .{&server});

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GET /x HTTP/1.0\r\n\r\n");
    try sw.interface.flush();

    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 2\r\n" ++
        "\r\n" ++
        "ok";
    var got: [resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(resp, got[0..]);

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));

    group.cancel(io);
    group.await(io) catch {};
}
