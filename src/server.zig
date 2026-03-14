const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const response = @import("response.zig");
const request = @import("request.zig");
const router = @import("router.zig");
const parse = @import("parse.zig");

pub const Method = enum(u8) {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,
    OTHER,
};

pub const Config = struct {
    /// Per-connection read buffer size.
    read_buffer: usize = 32 * 1024,
    /// Per-connection write buffer size.
    write_buffer: usize = 16 * 1024,
    /// Maximum request line length (bytes, including `\r\n`).
    max_request_line: usize = 8 * 1024,
    /// Maximum total header bytes (bytes, including line endings).
    max_header_bytes: usize = 32 * 1024,
    /// Unsafe fast path for benchmarking:
    /// - Only used when the matched route is eligible (exact route, no headers/query/params/middleware needs).
    /// - Skips header parsing (assumes no request body; ignores `Connection: close`).
    fast_benchmark: bool = false,
    /// Additional benchmark-only assumption: there are no request headers (i.e. request line is followed by `\r\n`).
    fast_benchmark_empty_headers: bool = false,
};

fn configField(comptime cfg: anytype, comptime name: []const u8, default: anytype) @TypeOf(default) {
    if (@hasField(@TypeOf(cfg), name)) return @field(cfg, name);
    return default;
}

fn methodToken(comptime m: Method) []const u8 {
    const tokens = comptime [_][]const u8{
        "GET",
        "POST",
        "PUT",
        "DELETE",
        "PATCH",
        "HEAD",
        "OPTIONS",
        "TRACE",
        "CONNECT",
        "OTHER",
    };
    return tokens[@intFromEnum(m)];
}

fn tupleLen(comptime t: anytype) usize {
    const info = @typeInfo(@TypeOf(t));
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("expected tuple");
    return info.@"struct".fields.len;
}

fn isExactPattern(comptime pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '{') != null) return false;
    if (std.mem.indexOfScalar(u8, pattern, '*') != null) return false;
    return true;
}

fn optsHasNeeds(comptime opts: anytype) bool {
    if (@hasField(@TypeOf(opts), "headers")) {
        if (parse.structFields(@field(opts, "headers")).len != 0) return true;
    }
    if (@hasField(@TypeOf(opts), "query")) {
        if (parse.structFields(@field(opts, "query")).len != 0) return true;
    }
    if (@hasField(@TypeOf(opts), "params")) {
        if (parse.structFields(@field(opts, "params")).len != 0) return true;
    }
    if (@hasField(@TypeOf(opts), "middlewares")) {
        if (tupleLen(@field(opts, "middlewares")) != 0) return true;
    }
    return false;
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
    const Routes = def.routes;
    const Context = if (@hasField(@TypeOf(def), "Context")) def.Context else void;
    const Middlewares = if (@hasField(@TypeOf(def), "middlewares")) def.middlewares else .{};
    const cfg = if (@hasField(@TypeOf(def), "config")) def.config else .{};

    const defaults: Config = .{};
    const Conf: Config = .{
        .read_buffer = configField(cfg, "read_buffer", defaults.read_buffer),
        .write_buffer = configField(cfg, "write_buffer", defaults.write_buffer),
        .max_request_line = configField(cfg, "max_request_line", defaults.max_request_line),
        .max_header_bytes = configField(cfg, "max_header_bytes", defaults.max_header_bytes),
        .fast_benchmark = configField(cfg, "fast_benchmark", defaults.fast_benchmark),
        .fast_benchmark_empty_headers = configField(cfg, "fast_benchmark_empty_headers", defaults.fast_benchmark_empty_headers),
    };

    const Compiled = router.Compiled(Context, Routes, Middlewares);
    const EmptyReq = request.Request(struct {}, struct {}, &.{});

    const routes_info = @typeInfo(@TypeOf(Routes));
    const route_fields = routes_info.@"struct".fields;

    const fast_single_route = comptime blk: {
        if (!Conf.fast_benchmark) break :blk false;
        if (route_fields.len != 1) break :blk false;
        if (tupleLen(Middlewares) != 0) break :blk false;
        const rd0 = @field(Routes, route_fields[0].name);
        if (!isExactPattern(rd0.pattern)) break :blk false;
        if (optsHasNeeds(rd0.options)) break :blk false;
        break :blk true;
    };

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
                const ConnFn = if (fast_single_route) handleConnFastSingle else handleConn;
                self.group.concurrent(self.io, ConnFn, .{ self, stream }) catch {
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
                const rid = Compiled.match(line.method, line.path, params_buf[0..Compiled.MaxParams]);

                var res: response.Res = undefined;
                var keep_alive: bool = false;

                if (rid) |route_index| {
                    const dr = (if (Conf.fast_benchmark) Compiled.dispatchFast else Compiled.dispatch)(
                        if (Context == void) {} else self.ctx,
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
                    var reqv = EmptyReq.init(a, line, &.{});
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

                const send_body = line.method != .HEAD;
                response.write(&sw.interface, res, keep_alive, send_body) catch {
                    return;
                };
                sw.interface.flush() catch {
                    return;
                };

                if (!keep_alive or res.close) return;
            }
        }

        fn handleConnFastSingle(self: *Self, stream: std.Io.net.Stream) Io.Cancelable!void {
            defer stream.close(self.io);

            comptime std.debug.assert(route_fields.len == 1);
            const rd0 = @field(Routes, route_fields[0].name);
            const method = rd0.method;
            const method_str = comptime methodToken(method);
            const pattern = rd0.pattern;
            const expected_line = comptime method_str ++ " " ++ pattern ++ " HTTP/1.1\r\n";
            const path_start: usize = comptime method_str.len + 1;
            const path_end: usize = comptime path_start + pattern.len;
            const handler = rd0.handler;
            const handler_params = @typeInfo(@TypeOf(handler)).@"fn".params;
            const CtxPtr = if (Context == void) void else *Context;
            const handler_ctx_only = comptime blk: {
                if (CtxPtr == void) break :blk false;
                if (handler_params.len != 1) break :blk false;
                if (handler_params[0].type) |pt| {
                    if (pt == CtxPtr) break :blk true;
                }
                break :blk false;
            };
            const handler_needs_req = comptime handler_params.len == 2 or (handler_params.len == 1 and !handler_ctx_only);

            var read_buf: [Conf.read_buffer]u8 = undefined;
            var write_buf: [Conf.write_buffer]u8 = undefined;

            var sr = stream.reader(self.io, &read_buf);
            var sw = stream.writer(self.io, &write_buf);

            // Benchmark-only: avoid arena resets and route dispatch overhead.
            // Assumes the route is exact and has no headers/query/params/middleware needs.
            while (true) {
                var linebuf: [expected_line.len]u8 = undefined;
                const line_bytes: []u8 = if (handler_needs_req) blk: {
                    sr.interface.readSliceAll(linebuf[0..]) catch |err| switch (err) {
                        error.EndOfStream => return,
                        else => {
                            writeSimple(self, &sw.interface, 400, "bad request");
                            return;
                        },
                    };
                    break :blk linebuf[0..];
                } else blk: {
                    const got = sr.interface.takeArray(expected_line.len) catch |err| switch (err) {
                        error.EndOfStream => return,
                        else => {
                            writeSimple(self, &sw.interface, 400, "bad request");
                            return;
                        },
                    };
                    break :blk got[0..];
                };

                if (!std.mem.eql(u8, line_bytes, expected_line)) {
                    writeSimple(self, &sw.interface, 400, "bad request");
                    return;
                }

                if (Conf.fast_benchmark_empty_headers) {
                    const crlf = sr.interface.takeArray(2) catch {
                        return;
                    };
                    if (crlf[0] != '\r' or crlf[1] != '\n') {
                        writeSimple(self, &sw.interface, 400, "bad request");
                        return;
                    }
                } else {
                    request.discardHeadersOnly(&sr.interface, Conf.max_header_bytes) catch |err| {
                        if (err == error.EndOfStream or err == error.ReadFailed) return;
                        const status: u16 = switch (err) {
                            error.HeadersTooLarge => 431,
                            else => 400,
                        };
                        writeSimple(self, &sw.interface, status, "bad request");
                        return;
                    };
                }

                const ctx: CtxPtr = if (Context == void) {} else self.ctx;
                const res: response.Res = if (!handler_needs_req) blk: {
                    if (handler_params.len == 0) break :blk try @call(.auto, handler, .{});
                    if (handler_ctx_only) break :blk try @call(.auto, handler, .{ctx});
                    unreachable;
                } else blk: {
                    const line: request.RequestLine = .{
                        .method = method,
                        .version = .http11,
                        .path = linebuf[path_start..path_end],
                        .query = linebuf[0..0],
                    };
                    var reqv = EmptyReq.init(self.gpa, line, &.{});
                    defer reqv.deinit(self.gpa);
                    reqv.reader = &sr.interface;

                    if (handler_params.len == 1) break :blk try @call(.auto, handler, .{&reqv});
                    if (handler_params.len == 2) break :blk try @call(.auto, handler, .{ ctx, &reqv });
                    @compileError("handler must be fn(), fn(req), fn(ctx), or fn(ctx, req)");
                };

                const send_body = method != .HEAD;
                response.write(&sw.interface, res, true, send_body) catch return;
                sw.interface.flush() catch return;
            }
        }
    };
}

test "benchmark fast-single route responds + pipelines" {
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
            .fast_benchmark = true,
            .fast_benchmark_empty_headers = true,
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

    const req = "GET /plaintext HTTP/1.1\r\n\r\n";
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
    var wb: [128]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll(req ++ req);
    try sw.interface.flush();

    var got1: [resp_len]u8 = undefined;
    var got2: [resp_len]u8 = undefined;
    try sr.interface.readSliceAll(got1[0..]);
    try sr.interface.readSliceAll(got2[0..]);
    try std.testing.expect(std.mem.eql(u8, got1[0..], resp));
    try std.testing.expect(std.mem.eql(u8, got2[0..], resp));

    group.cancel(io);
    group.await(io) catch {};
}

test "benchmark fast-single route handles full request headers" {
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
            .fast_benchmark = true,
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
        "Connection: keep-alive\r\n" ++
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

    try sw.interface.writeAll(req ++ req);
    try sw.interface.flush();

    var got1: [resp_len]u8 = undefined;
    var got2: [resp_len]u8 = undefined;
    try sr.interface.readSliceAll(got1[0..]);
    try sr.interface.readSliceAll(got2[0..]);
    try std.testing.expect(std.mem.eql(u8, got1[0..], resp));
    try std.testing.expect(std.mem.eql(u8, got2[0..], resp));

    group.cancel(io);
    group.await(io) catch {};
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
            .fast_benchmark = false,
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
        .config = .{
            .fast_benchmark = false,
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
        .config = .{
            .fast_benchmark = false,
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
