const std = @import("std");
const builtin = @import("builtin");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

const HeaderLineParts = [4][]const u8;
const empty_segment_body_const: *const [0][]const u8 = &.{};

pub const ChunkedWriter = struct {
    w: *std.Io.Writer,

    /// Writes one HTTP chunk (hex length + CRLF + payload + CRLF).
    pub fn writeAll(self: *ChunkedWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        var len_buf: [32]u8 = undefined;
        const len_hex = std.fmt.bufPrint(&len_buf, "{x}", .{bytes.len}) catch unreachable;

        var parts: HeaderLineParts = .{ len_hex, "\r\n", bytes, "\r\n" };
        try self.w.writeVecAll(&parts);
    }

    /// Writes the final zero-length chunk terminator.
    pub fn finish(self: *ChunkedWriter) !void {
        try self.w.writeAll("0\r\n\r\n");
    }
};

fn validateBodyType(comptime Body: type) void {
    if (Body == []const u8 or Body == [][]const u8 or Body == void) return;
    if (@typeInfo(Body) != .@"struct") {
        @compileError("unsupported response body type; expected []const u8, [][]const u8, void, or a struct exposing `pub fn body(self, comptime rctx, req, cw) !void`");
    }
    if (!@hasDecl(Body, "body")) {
        @compileError("custom response body type must expose `pub fn body(self: @This(), comptime rctx, req, cw: *response.ChunkedWriter) !void`");
    }
}

/// Maps a body representation to a concrete response type.
///
/// Expected `Body` shape:
/// - `[]const u8` for contiguous fixed-size bodies
/// - `[][]const u8` for segmented fixed-size bodies
/// - `void` for empty responses
/// - custom `struct` exposing:
///   `pub fn body(self: @This(), comptime rctx: zhttp.ReqCtx, req: rctx.TReadOnly(), cw: *response.ChunkedWriter) !void`
pub fn Response(comptime Body: type) type {
    validateBodyType(Body);
    return struct {
        status: std.http.Status = .ok,
        headers: []const Header = &.{},
        body: Body = blk: {
            if (Body == []const u8) break :blk "";
            if (Body == [][]const u8) break :blk @constCast(empty_segment_body_const[0..]);
            if (Body == void) break :blk {};
            break :blk undefined;
        },
        close: bool = false,
        format_connection_header: bool = true,
        format_content_length: bool = true,
        format_send_body: bool = true,
        format_body_len_override: ?usize = null,

        pub fn text(status: u16, body_bytes: []const u8) Res {
            if (Body != []const u8) @compileError("text() is only available on response.Response([]const u8)");
            return .{
                .status = @enumFromInt(status),
                .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
                .body = body_bytes,
            };
        }

        /// Formats a fixed-length byte response directly into a writer.
        pub fn format(self: @This(), w: *std.Io.Writer) !void {
            if (Body != []const u8) @compileError("format() is only available on response.Response([]const u8)");

            try writeStatusLine(w, self.status);

            if (self.format_connection_header) {
                try w.writeAll(if (!self.close) "connection: keep-alive\r\n" else "connection: close\r\n");
            }

            for (self.headers) |h| {
                var parts: HeaderLineParts = .{ h.name, ": ", h.value, "\r\n" };
                try w.writeVecAll(parts[0..]);
            }

            if (self.format_content_length) {
                try writeContentLength(w, self.format_body_len_override orelse self.body.len);
            } else {
                try w.writeAll("\r\n");
            }

            if (self.format_send_body) {
                try w.writeAll(self.body);
            }
        }
    };
}

pub const Res = Response([]const u8);
pub const SegmentedRes = Response([][]const u8);
pub const NoBodyRes = Response(void);

/// Reports whether a response overrides the connection to close.
pub fn closes(res: anytype) bool {
    return if (@hasField(@TypeOf(res), "close")) res.close else false;
}

/// Reports whether a response type supplies a prebuilt writer hook.
///
/// Prebuilt response types expose:
/// `pub fn write(self: @This(), w: *std.Io.Writer, keep_alive: bool, send_body: bool) !void`
///
/// When serialized by the server, these writes bypass the per-connection HTTP
/// writer buffer automatically so the prebuilt bytes go straight to the
/// socket writer.
pub fn hasPrebuiltWrite(comptime ResT: type) bool {
    return @hasDecl(ResT, "write");
}

/// Converts values in the range [0, 100) to a base 10 string.
pub fn digits2(value: u8) [2]u8 {
    if (builtin.mode == .ReleaseSmall) {
        return .{ @intCast('0' + value / 10), @intCast('0' + value % 10) };
    } else {
        return "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899"[value * 2 ..][0..2].*;
    }
}

pub fn write(
    w: *std.Io.Writer,
    res: Res,
    keep_alive: bool,
    send_body: bool,
) !void {
    try writeAny({}, {}, w, res, keep_alive, send_body);
}

fn writeHeaders(
    w: *std.Io.Writer,
    headers: []const Header,
    close_conn: bool,
) !void {
    try w.writeAll(if (close_conn) "connection: close\r\n" else "connection: keep-alive\r\n");
    for (headers) |h| {
        var parts: HeaderLineParts = .{ h.name, ": ", h.value, "\r\n" };
        try w.writeVecAll(parts[0..]);
    }
}

/// Writes any supported response type.
///
/// Expected shapes:
/// - `rctx` is a request context value (`zhttp.ReqCtx`).
/// - `req_ro` is `rctx.TReadOnly()` for that same context.
/// - `res` is either:
///   - `response.Response(Body)` (or compatible struct) with fields:
///     `status`, `headers`, `body`, and optional `close`, or
///   - a prebuilt response struct exposing
///     `pub fn write(self: @This(), w: *std.Io.Writer, keep_alive: bool, send_body: bool) !void`
///     and optional `close: bool`.
pub fn writeAny(
    comptime rctx: anytype,
    req_ro: anytype,
    w: *std.Io.Writer,
    res: anytype,
    keep_alive: bool,
    send_body: bool,
) !void {
    const close_conn = (!keep_alive) or closes(res);
    const effective_keep_alive = !close_conn;
    const ResT = @TypeOf(res);
    if (comptime hasPrebuiltWrite(ResT)) {
        try @call(.auto, ResT.write, .{ res, w, effective_keep_alive, send_body });
        return;
    }

    const Body = @TypeOf(res.body);
    validateBodyType(Body);
    const streams_body = comptime switch (@typeInfo(Body)) {
        .@"struct" => @hasDecl(Body, "body"),
        else => false,
    };

    if (streams_body) {
        try writeStatusLine(w, res.status);
        try writeHeaders(w, res.headers, close_conn);
        // Custom body structs always stream through chunked encoding. They receive
        // the readonly request wrapper so serialization can inspect request state
        // without re-entering middleware overrides.
        try w.writeAll("transfer-encoding: chunked\r\n\r\n");
        if (!send_body) return;

        var cw: ChunkedWriter = .{ .w = w };
        try @call(.auto, Body.body, .{ res.body, rctx, req_ro, &cw });
        try cw.finish();
        return;
    }

    try writeStatusLine(w, res.status);
    try writeHeaders(w, res.headers, close_conn);

    if (Body == []const u8) {
        try writeContentLength(w, res.body.len);
        if (send_body) {
            try w.writeAll(res.body);
        }
    } else if (Body == [][]const u8) {
        var body_len: usize = 0;
        for (res.body) |part| {
            const sum, const ov = @addWithOverflow(body_len, part.len);
            if (ov != 0) unreachable;
            body_len = sum;
        }
        try writeContentLength(w, body_len);
        if (send_body) {
            if (res.body.len == 1) {
                try w.writeAll(res.body[0]);
            } else if (res.body.len != 0) {
                // `writeVecAll` mutates the slice list while advancing through
                // short writes. Copy metadata to writable stack storage so
                // callers can pass const-backed segment arrays safely.
                var i: usize = 0;
                while (i < res.body.len) {
                    var vec_copy: [16][]const u8 = undefined;
                    const n = @min(vec_copy.len, res.body.len - i);
                    @memcpy(vec_copy[0..n], res.body[i .. i + n]);
                    try w.writeVecAll(vec_copy[0..n]);
                    i += n;
                }
            }
        }
    } else if (Body == void) {
        try writeContentLength(w, 0);
    }
}

/// Writes a prebuilt upgrade response without injecting connection/body headers.
///
/// Expected `res` shape:
/// - fields `status: std.http.Status` and `headers: []const response.Header`.
pub fn writeUpgrade(w: *std.Io.Writer, res: anytype) !void {
    try writeStatusLine(w, res.status);
    for (res.headers) |h| {
        var parts: HeaderLineParts = .{ h.name, ": ", h.value, "\r\n" };
        try w.writeVecAll(parts[0..]);
    }
    try w.writeAll("\r\n");
}

/// Writes the HTTP/1.1 status line.
fn writeStatusLine(w: *std.Io.Writer, status: std.http.Status) !void {
    const status_code: u16 = @intCast(@intFromEnum(status));
    var status_buf: [3]u8 = undefined;
    status_buf[1..3].* = digits2(@intCast(status_code % 100));
    status_buf[0] = @intCast('0' + (status_code / 100) % 10);
    var parts: [5][]const u8 = .{ "HTTP/1.1 ", &status_buf, "", "", "" };
    if (status.phrase()) |phrase| {
        parts[2] = " ";
        parts[3] = phrase;
    }
    parts[4] = "\r\n";
    try w.writeVecAll(parts[0..]);
}

/// Writes the `content-length` header and header terminator.
fn writeContentLength(w: *std.Io.Writer, body_len: usize) !void {
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body_len}) catch unreachable;
    var parts: [3][]const u8 = .{ "content-length: ", len_str, "\r\n\r\n" };
    try w.writeVecAll(parts[0..]);
}

test "write: HEAD omits body but keeps content-length" {
    const res = Res.text(200, "hello");
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try write(&w, res, true, false);

    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 5\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected, out[0..w.end]);
}

test "writeAny: segmented bodies accept const-backed segment tables" {
    const const_parts = [_][]const u8{
        "segment",
        "-",
        "body",
        "\n",
    };
    const res: SegmentedRes = .{
        .status = .ok,
        .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
        .body = @constCast(const_parts[0..]),
    };

    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try writeAny({}, {}, &w, res, true, true);

    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 13\r\n" ++
        "\r\n" ++
        "segment-body\n";
    try std.testing.expectEqualStrings(expected, out[0..w.end]);
}

test "ChunkedWriter and Res.text: direct helpers work" {
    const res = Res.text(201, "hello");
    try std.testing.expectEqual(@as(u16, 201), @intFromEnum(res.status));
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", res.headers[0].value);

    var out: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    var cw: ChunkedWriter = .{ .w = &w };
    try cw.writeAll("");
    try cw.writeAll("hi");
    try cw.finish();
    try std.testing.expectEqualStrings("2\r\nhi\r\n0\r\n\r\n", out[0..w.end]);
}

test "Res.format: upgrade-like formatting omits injected headers" {
    var res: Res = .{
        .status = .switching_protocols,
        .headers = &.{
            .{ .name = "connection", .value = "Upgrade" },
            .{ .name = "upgrade", .value = "websocket" },
        },
    };
    res.format_connection_header = false;
    res.format_content_length = false;
    res.format_send_body = false;
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try res.format(&w);

    const expected =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "connection: Upgrade\r\n" ++
        "upgrade: websocket\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected, out[0..w.end]);
}

test "write: keep-alive false emits close" {
    const res = Res.text(200, "x");
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try write(&w, res, false, true);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "connection: close\r\n") != null);
}

test "write: res.close forces close" {
    var res = Res.text(200, "x");
    res.close = true;
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try write(&w, res, true, true);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "connection: close\r\n") != null);
}

test "writeAny: custom writer hook receives effective keep-alive" {
    const Custom = struct {
        close: bool = false,

        pub fn write(self: @This(), w: *std.Io.Writer, keep_alive: bool, send_body: bool) !void {
            _ = self;
            try w.writeAll(if (keep_alive)
                if (send_body) "ka-body" else "ka-head"
            else if (send_body)
                "close-body"
            else
                "close-head");
        }
    };

    var out1: [64]u8 = undefined;
    var w1 = std.Io.Writer.fixed(out1[0..]);
    try writeAny({}, {}, &w1, Custom{}, true, true);
    try std.testing.expectEqualStrings("ka-body", out1[0..w1.end]);

    var out2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(out2[0..]);
    try writeAny({}, {}, &w2, Custom{ .close = true }, true, false);
    try std.testing.expectEqualStrings("close-head", out2[0..w2.end]);
}

test "writeUpgrade: does not inject connection or content-length" {
    const res: Res = .{
        .status = .switching_protocols,
        .headers = &.{
            .{ .name = "connection", .value = "Upgrade" },
            .{ .name = "upgrade", .value = "websocket" },
        },
    };
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try writeUpgrade(&w, res);

    const expected =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "connection: Upgrade\r\n" ++
        "upgrade: websocket\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected, out[0..w.end]);
}

test "writeAny: segmented body uses content-length sum and writes all parts" {
    const parts = [_][]const u8{ "hello", " ", "world" };
    const res: SegmentedRes = .{
        .status = .ok,
        .body = @constCast(parts[0..]),
    };
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try writeAny({}, {}, &w, res, true, true);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "content-length: 11\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out[0..w.end], "\r\nhello world"));
}

test "writeAny: void body writes content-length zero" {
    const res: NoBodyRes = .{ .status = .no_content };
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try writeAny({}, {}, &w, res, true, true);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "content-length: 0\r\n") != null);
}

test "writeAny: custom body writes chunked encoding" {
    const FakeReqCtx = struct {
        pub fn TReadOnly(comptime _: @This()) type {
            return struct {
                seen: *bool,
            };
        }
    }{};
    const StreamBody = struct {
        pub fn body(_: @This(), comptime _: @TypeOf(FakeReqCtx), req: FakeReqCtx.TReadOnly(), cw: *ChunkedWriter) !void {
            req.seen.* = true;
            try cw.writeAll("hello");
            try cw.writeAll("!");
        }
    };
    const res: Response(StreamBody) = .{
        .status = .ok,
        .body = .{},
    };
    var seen = false;
    const req_ro: FakeReqCtx.TReadOnly() = .{ .seen = &seen };
    var out: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try writeAny(FakeReqCtx, req_ro, &w, res, true, true);
    try std.testing.expect(seen);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "transfer-encoding: chunked\r\n\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out[0..w.end], "5\r\nhello\r\n1\r\n!\r\n0\r\n\r\n"));
}

test "writeAny: custom body is not invoked when send_body is false" {
    const FakeReqCtx = struct {
        pub fn TReadOnly(comptime _: @This()) type {
            return struct {
                seen: *bool,
            };
        }
    }{};
    const StreamBody = struct {
        pub fn body(_: @This(), comptime _: @TypeOf(FakeReqCtx), req: FakeReqCtx.TReadOnly(), _: *ChunkedWriter) !void {
            req.seen.* = true;
        }
    };
    const res: Response(StreamBody) = .{
        .status = .ok,
        .body = .{},
    };
    var seen = false;
    const req_ro: FakeReqCtx.TReadOnly() = .{ .seen = &seen };
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try writeAny(FakeReqCtx, req_ro, &w, res, true, false);
    try std.testing.expect(!seen);
    try std.testing.expect(std.mem.endsWith(u8, out[0..w.end], "transfer-encoding: chunked\r\n\r\n"));
}

test "Response: maps supported body shapes" {
    try std.testing.expect(Response([]const u8) == Res);
    try std.testing.expect(Response([][]const u8) == SegmentedRes);
    try std.testing.expect(Response(void) == NoBodyRes);
}

test "digits2: handles boundaries" {
    try std.testing.expectEqualStrings("00", digits2(0)[0..]);
    try std.testing.expectEqualStrings("07", digits2(7)[0..]);
    try std.testing.expectEqualStrings("42", digits2(42)[0..]);
    try std.testing.expectEqualStrings("99", digits2(99)[0..]);
}

test "Res.format: content-length override is respected" {
    var res = Res.text(200, "hello");
    res.format_body_len_override = 123;
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try res.format(&w);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "content-length: 123\r\n") != null);
}

test "Res.format: optional content-length can be omitted while body is sent" {
    var res = Res.text(200, "abc");
    res.format_content_length = false;
    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try res.format(&w);

    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "content-length:") == null);
    try std.testing.expect(std.mem.endsWith(u8, out[0..w.end], "\r\nabc"));
}
