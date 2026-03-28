const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const response = @import("response.zig");
const request = @import("request.zig");
const router = @import("router.zig");
const middleware = @import("middleware.zig");
const parse = @import("parse.zig");

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
    write_buffer: usize = 4 * 1024,
    /// Enable TCP_NODELAY (disables Nagle). Off by default.
    tcp_nodelay: bool = false,
    /// Maximum request line length (bytes, including `\r\n`).
    max_request_line: usize = 8 * 1024,
    /// Maximum total header bytes (bytes, including line endings).
    max_header_bytes: usize = 32 * 1024,
};

fn configField(comptime cfg: anytype, comptime name: []const u8) @FieldType(Config, name) {
    return @field(if (@hasField(@TypeOf(cfg), name)) cfg else Config{}, name);
}

/// Server definition options (`def`) are provided at comptime.
///
/// Supported fields:
/// - `Context: type`      Optional user context type. Defaults to `void`.
/// - `middlewares: tuple` Optional global middleware types. Defaults to `.{}`.
/// - `routes: struct`     Required routes tuple/struct: `.{ zhttp.get(...), ... }`.
/// - `config: struct`     Optional config overrides (fields match `zhttp.server.Config`).
/// - `error_handler`      Optional fallback transport/dispatch error handler:
///                        `fn(*Server, *Io.Writer, comptime ErrorSet: type, err: ErrorSet) router.Action`.
/// - `not_found_handler`  Optional fallback handler override for route misses.
/// - `not_found_options`  Optional request options for the fallback handler (`headers`, `query`, `middlewares`).
pub fn Server(comptime def: anytype) type {
    if (!@hasField(@TypeOf(def), "routes")) @compileError("Server definition must include `.routes = .{ ... }`");
    const Context = if (@hasField(@TypeOf(def), "Context")) def.Context else void;
    const cfg = if (@hasField(@TypeOf(def), "config")) def.config else .{};

    const Conf: Config = .{
        .read_buffer = configField(cfg, "read_buffer"),
        .write_buffer = configField(cfg, "write_buffer"),
        .tcp_nodelay = configField(cfg, "tcp_nodelay"),
        .max_request_line = configField(cfg, "max_request_line"),
        .max_header_bytes = configField(cfg, "max_header_bytes"),
    };

    const DefT = @TypeOf(def);
    const Middlewares = if (@hasField(DefT, "middlewares")) def.middlewares else .{};
    const MiddlewareRoutes = middleware.routes(Middlewares);
    const Routes = router.mergeRoutes(def.routes, MiddlewareRoutes);
    const Compiled = router.Compiled(Context, Routes, Middlewares);
    const DefaultNotFound = struct {
        fn handler(_: anytype) !response.Res {
            return response.Res.text(404, "not found");
        }
    };
    const NotFoundHandler = if (@hasField(DefT, "not_found_handler")) def.not_found_handler else DefaultNotFound.handler;
    const NotFoundOptions = if (@hasField(DefT, "not_found_options")) def.not_found_options else .{};
    const NotFoundCompiled = router.Compiled(Context, .{router.get("/", NotFoundHandler, NotFoundOptions)}, Middlewares);

    return struct {
        io: Io,
        gpa: Allocator,
        listener: std.Io.net.Server,
        group: Io.Group = .init,
        ctx: if (Context == void) void else *Context,

        const Self = @This();
        pub const config = Conf;
        const Action = router.Action;
        const RouteFn = *const fn (
            server: *Self,
            r: *Io.Reader,
            w: *Io.Writer,
            stream: *const std.Io.net.Stream,
            line: request.RequestLine,
            a: Allocator,
        ) Compiled.DispatchError!Action;
        const NotFoundFn = *const fn (
            server: *Self,
            r: *Io.Reader,
            w: *Io.Writer,
            stream: *const std.Io.net.Stream,
            line: request.RequestLine,
            a: Allocator,
        ) NotFoundCompiled.DispatchError!Action;
        const DefaultErrorHandler = struct {
            fn call(server: *Self, w: *Io.Writer, comptime ErrorSet: type, _: ErrorSet) Action {
                server.writeSimple(w, 500, "internal error");
                return .close;
            }
        };
        const ErrorHandler = if (@hasField(DefT, "error_handler")) def.error_handler else DefaultErrorHandler.call;

        pub fn init(
            gpa: Allocator,
            io: Io,
            address: std.Io.net.IpAddress,
            ctx: if (Context == void) void else *Context,
        ) !Self {
            const listener = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
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
                    error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => continue, // maybe wait or smthng
                    error.ConnectionAborted, error.BlockedByFirewall, error.ProtocolFailure => continue,
                    error.SocketNotListening, error.Canceled => return error.Canceled,
                    error.NetworkDown => return,
                    error.WouldBlock => return,
                    error.Unexpected => return,
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

        fn validateErrorHandler() void {
            const info = @typeInfo(@TypeOf(ErrorHandler));
            if (info != .@"fn") @compileError("error_handler must be a function");
            const params = info.@"fn".params;
            if (params.len != 4) @compileError("error_handler must be fn(*Server, *Io.Writer, comptime ErrorSet: type, err: ErrorSet) router.Action");
            if (params[0].type != *Self and params[0].type != null) @compileError("error_handler first param must be *Server");
            if (params[1].type != *Io.Writer and params[1].type != null) @compileError("error_handler second param must be *Io.Writer");
            if (params[2].type != type and params[2].type != null) @compileError("error_handler third param must be comptime ErrorSet: type");
            if (info.@"fn".return_type != Action) @compileError("error_handler must return router.Action");
        }

        fn callErrorHandler(self: *Self, w: *Io.Writer, comptime ErrorSet: type, err: ErrorSet) Action {
            comptime validateErrorHandler();
            return @call(.auto, ErrorHandler, .{ self, w, ErrorSet, err });
        }

        pub fn handleHandlerError(self: *Self, w: *Io.Writer, comptime ErrorSet: type, err: ErrorSet) Action {
            return self.callErrorHandler(w, ErrorSet, err);
        }

        inline fn handleDispatchServerError(self: *Self, w: *Io.Writer, err: anytype) Action {
            return switch (err) {
                error.EndOfStream, error.ReadFailed, error.WriteFailed => .close,
                error.HeadersTooLarge => blk2: {
                    self.writeSimple(w, 431, "bad request");
                    break :blk2 .close;
                },
                error.MissingRequired,
                error.BadValue,
                error.InvalidPercentEncoding,
                error.BadRequest,
                error.StreamTooLong,
                => blk2: {
                    self.writeSimple(w, 400, "bad request");
                    break :blk2 .close;
                },
                error.OutOfMemory => blk2: {
                    self.writeSimple(w, 500, "internal error");
                    break :blk2 .close;
                },
            };
        }

        fn handleConn(self: *Self, stream: std.Io.net.Stream) Io.Cancelable!void {
            if (Conf.tcp_nodelay) setTcpNoDelay(&stream);

            var read_buf: [Conf.read_buffer]u8 = undefined;
            var write_buf: [Conf.write_buffer]u8 = undefined;

            var sr = stream.reader(self.io, &read_buf);
            var sw = stream.writer(self.io, &write_buf);

            blk: switch (Action.@"continue") {
                .@"continue" => {
                    var arena = std.heap.ArenaAllocator.init(self.gpa);
                    defer arena.deinit();
                    const a = arena.allocator();

                    const line = request.parseRequestLineBorrowed(&sr.interface, Conf.max_request_line) catch |err| {
                        continue :blk switch (err) {
                            error.EndOfStream, error.ReadFailed => .close,
                            error.UriTooLong => blk2: {
                                self.writeSimple(&sw.interface, 414, "bad request");
                                break :blk2 .close;
                            },
                            error.BadRequest => blk2: {
                                self.writeSimple(&sw.interface, 400, "bad request");
                                break :blk2 .close;
                            },
                            error.OutOfMemory => blk2: {
                                self.writeSimple(&sw.interface, 500, "internal error");
                                break :blk2 .close;
                            },
                        };
                    };

                    continue :blk (if (Compiled.match(line.method, line.path)) |idx| switch (idx) {
                        inline 0...(Compiled.RouteCount - 1) => |c_idx| routeAction(c_idx)(self, &sr.interface, &sw.interface, &stream, line, a) catch |err| self.handleDispatchServerError(&sw.interface, err),
                        else => unreachable,
                    } else notFoundAction()(self, &sr.interface, &sw.interface, &stream, line, a) catch |err| self.handleDispatchServerError(&sw.interface, err));
                },
                .close => stream.close(self.io),
                .upgraded => {},
            }
        }

        fn routeAction(comptime route_index: u16) RouteFn {
            return struct {
                fn call(
                    server: *Self,
                    r: *Io.Reader,
                    w: *Io.Writer,
                    stream: *const std.Io.net.Stream,
                    line: request.RequestLine,
                    a: Allocator,
                ) Compiled.DispatchError!Action {
                    var params_buf: [Compiled.RouteParamCounts[route_index]][]u8 = undefined;
                    return Compiled.dispatch(
                        server,
                        a,
                        r,
                        w,
                        stream,
                        line,
                        route_index,
                        params_buf[0..Compiled.RouteParamCounts[route_index]],
                        Conf.max_header_bytes,
                    );
                }
            }.call;
        }

        fn notFoundAction() NotFoundFn {
            return struct {
                fn call(
                    server: *Self,
                    r: *Io.Reader,
                    w: *Io.Writer,
                    stream: *const std.Io.net.Stream,
                    line: request.RequestLine,
                    a: Allocator,
                ) NotFoundCompiled.DispatchError!Action {
                    var params_buf: [NotFoundCompiled.RouteParamCounts[0]][]u8 = undefined;
                    return NotFoundCompiled.dispatch(
                        server,
                        a,
                        r,
                        w,
                        stream,
                        line,
                        0,
                        params_buf[0..NotFoundCompiled.RouteParamCounts[0]],
                        Conf.max_header_bytes,
                    );
                }
            }.call;
        }
    };
}

fn primeSocketBackend() void {
    if (builtin.os.tag == .windows) return;

    // Work around a std.Io test-process quirk where the first high-level
    // loopback listen can fail unless the socket backend has been touched once.
    const posix = std.posix;
    const rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    if (posix.errno(rc) == .SUCCESS) {
        _ = posix.system.close(@intCast(rc));
    }
}

test "Connection: close header closes socket" {
    const Bench = struct {
        fn plaintext(_: anytype) !response.Res {
            return .{
                .status = .ok,
                .headers = &.{
                    .{ .name = "Server", .value = "F" },
                    .{ .name = "Content-Type", .value = "text/plain" },
                    .{ .name = "Date", .value = "Wed, 24 Feb 2021 12:00:00 GMT" },
                },
                .body = "Hello, World!",
            };
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

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
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    const req =
        "GET /plaintext HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "content-length: 13\r\n" ++
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

test "unknown path returns 404 and keeps connection" {
    const Handlers = struct {
        fn ok(_: anytype) !response.Res {
            return response.Res.text(200, "ok");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", Handlers.ok, .{}),
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
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GET /nope HTTP/1.1\r\nHost: x\r\n\r\n");
    try sw.interface.flush();

    const not_found_resp =
        "HTTP/1.1 404 Not Found\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 9\r\n" ++
        "\r\n" ++
        "not found";
    var got_nf: [not_found_resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got_nf[0..]);
    try std.testing.expectEqualStrings(not_found_resp, got_nf[0..]);

    try sw.interface.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\n\r\n");
    try sw.interface.flush();

    const ok_resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 2\r\n" ++
        "\r\n" ++
        "ok";
    var got_ok: [ok_resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got_ok[0..]);
    try std.testing.expectEqualStrings(ok_resp, got_ok[0..]);

    group.cancel(io);
    group.await(io) catch {};
}

test "not_found_handler can parse query headers and body" {
    const Handlers = struct {
        fn ok(_: anytype) !response.Res {
            return response.Res.text(200, "ok");
        }

        fn missing(req: anytype) !response.Res {
            const name = req.queryParam(.name) orelse "world";
            const host = req.header(.host) orelse "(no host)";
            const body = try req.bodyAll(1024);
            const out = try std.fmt.allocPrint(req.allocator(), "miss {s} {s} {s}", .{ name, host, body });
            return response.Res.text(200, out);
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", Handlers.ok, .{}),
        },
        .not_found_handler = Handlers.missing,
        .not_found_options = .{
            .query = struct {
                name: parse.Optional(parse.String),
            },
            .headers = struct {
                host: parse.Optional(parse.String),
            },
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
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [512]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    const req =
        "POST /missing?name=zig HTTP/1.1\r\n" ++
        "Host: example\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello";
    try sw.interface.writeAll(req);
    try sw.interface.flush();

    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 22\r\n" ++
        "\r\n" ++
        "miss zig example hello";
    var got: [resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(resp, got[0..]);

    try sw.interface.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\n\r\n");
    try sw.interface.flush();

    const ok_resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 2\r\n" ++
        "\r\n" ++
        "ok";
    var got_ok: [ok_resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got_ok[0..]);
    try std.testing.expectEqualStrings(ok_resp, got_ok[0..]);

    group.cancel(io);
    group.await(io) catch {};
}

test "HEAD response omits body" {
    const Handlers = struct {
        fn ok(_: anytype) !response.Res {
            return response.Res.text(200, "hello");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", Handlers.ok, .{}),
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
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("HEAD /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try sw.interface.flush();

    const head_resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 5\r\n" ++
        "\r\n";
    var got: [head_resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(head_resp, got[0..]);

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));

    group.cancel(io);
    group.await(io) catch {};
}

test "bad request line returns 400" {
    const Handlers = struct {
        fn ok(_: anytype) !response.Res {
            return response.Res.text(200, "ok");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", Handlers.ok, .{}),
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
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GARBAGE\r\n\r\n");
    try sw.interface.flush();

    const bad_resp =
        "HTTP/1.1 400 Bad Request\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 11\r\n" ++
        "\r\n" ++
        "bad request";
    var got: [bad_resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(bad_resp, got[0..]);

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));

    group.cancel(io);
    group.await(io) catch {};
}

test "custom error_handler handles handler errors only" {
    const Handlers = struct {
        fn boom(_: anytype) !response.Res {
            return error.Boom;
        }

        fn onError(_: anytype, w: *Io.Writer, comptime ErrorSet: type, _: ErrorSet) router.Action {
            const body = "custom boom";
            response.write(w, response.Res.text(499, body), false, true) catch unreachable;
            w.flush() catch unreachable;
            return .close;
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/boom", Handlers.boom, .{}),
        },
        .error_handler = Handlers.onError,
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.init(std.testing.allocator, io, addr0, {});
    defer server.deinit();
    const port: u16 = server.listener.socket.address.getPort();

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, SrvT.run, .{&server});

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };

    {
        var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [256]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        try sw.interface.writeAll("GARBAGE\r\n\r\n");
        try sw.interface.flush();

        const resp =
            "HTTP/1.1 400 Bad Request\r\n" ++
            "connection: close\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 11\r\n" ++
            "\r\n" ++
            "bad request";
        var got: [resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(resp, got[0..]);
    }

    {
        var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [256]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        try sw.interface.writeAll("GET /boom HTTP/1.1\r\nHost: x\r\n\r\n");
        try sw.interface.flush();

        const resp =
            "HTTP/1.1 499\r\n" ++
            "connection: close\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 11\r\n" ++
            "\r\n" ++
            "custom boom";
        var got: [resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(resp, got[0..]);
    }

    group.cancel(io);
    group.await(io) catch {};
}

test "handler res.close closes socket" {
    const Handlers = struct {
        fn close_me(_: anytype) !response.Res {
            var r = response.Res.text(200, "bye");
            r.close = true;
            return r;
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

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
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
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

    const io = std.testing.io;
    primeSocketBackend();

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
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
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

test "upgrade_handler: 101 triggers upgrade callback and stream ownership" {
    const State = struct {
        upgraded: bool = false,
    };

    const Handlers = struct {
        fn ws(_: anytype) !response.Res {
            return .{
                .status = .switching_protocols,
                .headers = &.{
                    .{ .name = "connection", .value = "Upgrade" },
                    .{ .name = "upgrade", .value = "websocket" },
                },
            };
        }

        fn onUpgrade(server: anytype, stream: *const std.Io.net.Stream, _: *Io.Reader, _: *Io.Writer, _: request.RequestLine, _: response.Res) void {
            server.ctx.upgraded = true;
            stream.close(server.io);
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    var state: State = .{};
    const SrvT = Server(.{
        .Context = State,
        .routes = .{
            router.get("/ws", Handlers.ws, .{
                .upgrade_handler = Handlers.onUpgrade,
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.init(std.testing.allocator, io, addr0, &state);
    defer server.deinit();
    const port: u16 = server.listener.socket.address.getPort();

    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, SrvT.run, .{&server});

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll(
        "GET /ws HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "\r\n",
    );
    try sw.interface.flush();

    const expected =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "connection: Upgrade\r\n" ++
        "upgrade: websocket\r\n" ++
        "\r\n";
    var got: [expected.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(expected, got[0..]);

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));
    try std.testing.expect(state.upgraded);

    group.cancel(io);
    group.await(io) catch {};
}
