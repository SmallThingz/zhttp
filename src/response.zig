const std = @import("std");
const builtin = @import("builtin");

pub const Header = struct {
    /// Stores `name`.
    name: []const u8,
    /// Stores `value`.
    value: []const u8,
};

const HeaderLineParts = [4][]const u8;

pub const ChunkedWriter = struct {
    /// Stores `w`.
    w: *std.Io.Writer,

    /// Writes one HTTP chunk (hex length + CRLF + payload + CRLF).
    pub fn writeAll(self: *ChunkedWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        var len_buf: [32]u8 = undefined;
        const len_hex = std.fmt.bufPrint(&len_buf, "{x}", .{bytes.len}) catch unreachable;
        try self.w.writeAll(len_hex);
        try self.w.writeAll("\r\n");
        try self.w.writeAll(bytes);
        try self.w.writeAll("\r\n");
    }

    /// Writes the final zero-length chunk terminator.
    pub fn finish(self: *ChunkedWriter) !void {
        try self.w.writeAll("0\r\n\r\n");
    }
};

pub const BodyStream = struct {
    /// Stores `writeFn`.
    writeFn: *const fn (cw: *ChunkedWriter) std.Io.Writer.Error!void,
};

const empty_segment_body_const: *const [0][]const u8 = &.{};

pub const Res = struct {
    /// Stores `status`.
    status: std.http.Status = .ok,
    /// Stores `headers`.
    headers: []const Header = &.{},
    /// Stores `body`.
    body: []const u8 = "",
    /// Stores `close`.
    close: bool = false,
    /// Stores `format_connection_header`.
    format_connection_header: bool = true,
    /// Stores `format_content_length`.
    format_content_length: bool = true,
    /// Stores `format_send_body`.
    format_send_body: bool = true,
    /// Stores `format_body_len_override`.
    format_body_len_override: ?usize = null,

    /// Implements text.
    pub fn text(status: u16, body: []const u8) Res {
        return .{
            .status = @enumFromInt(status),
            .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            .body = body,
        };
    }

    /// Implements format.
    pub fn format(self: Res, w: *std.Io.Writer) !void {
        try writeStatusLine(w, self.status);

        if (self.format_connection_header) {
            const connection_line: []const u8 = if (!self.close) "connection: keep-alive\r\n" else "connection: close\r\n";
            try w.writeAll(connection_line);
        }

        for (self.headers) |h| {
            try w.writeAll(h.name);
            try w.writeAll(": ");
            try w.writeAll(h.value);
            try w.writeAll("\r\n");
        }

        if (self.format_content_length) {
            var len_buf: [32]u8 = undefined;
            const body_len: usize = self.format_body_len_override orelse self.body.len;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body_len}) catch unreachable;
            var line_buf: [64]u8 = undefined;
            var line_len: usize = 0;
            const prefix = "content-length: ";
            @memcpy(line_buf[line_len .. line_len + prefix.len], prefix);
            line_len += prefix.len;
            @memcpy(line_buf[line_len .. line_len + len_str.len], len_str);
            line_len += len_str.len;
            @memcpy(line_buf[line_len .. line_len + 4], "\r\n\r\n");
            line_len += 4;
            try w.writeAll(line_buf[0..line_len]);
        } else {
            try w.writeAll("\r\n");
        }

        if (self.format_send_body and self.body.len != 0) {
            try w.writeAll(self.body);
        }
    }
};

pub const SegmentedRes = struct {
    /// Stores `status`.
    status: std.http.Status = .ok,
    /// Stores `headers`.
    headers: []const Header = &.{},
    /// Stores `body`.
    body: [][]const u8 = @constCast(empty_segment_body_const[0..]),
    /// Stores `close`.
    close: bool = false,
};

pub const StreamRes = struct {
    /// Stores `status`.
    status: std.http.Status = .ok,
    /// Stores `headers`.
    headers: []const Header = &.{},
    /// Stores `body`.
    body: BodyStream,
    /// Stores `close`.
    close: bool = false,
};

/// Maps a body representation to a concrete response type.
pub fn Response(comptime Body: type) type {
    if (Body == []const u8) return Res;
    if (Body == [][]const u8) return SegmentedRes;
    if (Body == BodyStream) return StreamRes;
    @compileError("unsupported response body type; expected []const u8, [][]const u8, or response.BodyStream");
}

/// Computes the total byte length across all segmented body parts.
fn segmentedContentLength(parts: [][]const u8) usize {
    var total: usize = 0;
    for (parts) |p| {
        const sum, const ov = @addWithOverflow(total, p.len);
        if (ov != 0) unreachable;
        total = sum;
    }
    return total;
}

/// Converts values in the range [0, 100) to a base 10 string.
pub fn digits2(value: u8) [2]u8 {
    if (builtin.mode == .ReleaseSmall) {
        return .{ @intCast('0' + value / 10), @intCast('0' + value % 10) };
    } else {
        return "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899"[value * 2 ..][0..2].*;
    }
}

/// Implements write.
pub fn write(
    w: *std.Io.Writer,
    res: Res,
    keep_alive: bool,
    send_body: bool,
) !void {
    try writeStatusLine(w, res.status);

    const close_conn = (!keep_alive) or res.close;
    try w.writeAll(if (close_conn) "connection: close\r\n" else "connection: keep-alive\r\n");

    for (res.headers) |h| {
        var parts: HeaderLineParts = .{ h.name, ": ", h.value, "\r\n" };
        try w.writeVecAll(parts[0..]);
    }

    try writeContentLength(w, res.body.len);

    if (send_body and res.body.len != 0) {
        try w.writeAll(res.body);
    }
}

/// Writes any supported response type.
pub fn writeAny(
    w: *std.Io.Writer,
    res: anytype,
    keep_alive: bool,
    send_body: bool,
) !void {
    const T = @TypeOf(res);
    if (T == Res) return write(w, res, keep_alive, send_body);
    if (T == SegmentedRes) return writeSegmented(w, res, keep_alive, send_body);
    if (T == StreamRes) return writeStream(w, res, keep_alive, send_body);
    @compileError("unsupported response type; expected response.Res, response.SegmentedRes, or response.StreamRes");
}

/// Writes a segmented fixed-length response.
fn writeSegmented(
    w: *std.Io.Writer,
    res: SegmentedRes,
    keep_alive: bool,
    send_body: bool,
) !void {
    try writeStatusLine(w, res.status);

    const close_conn = (!keep_alive) or res.close;
    try w.writeAll(if (close_conn) "connection: close\r\n" else "connection: keep-alive\r\n");

    for (res.headers) |h| {
        var parts: HeaderLineParts = .{ h.name, ": ", h.value, "\r\n" };
        try w.writeVecAll(parts[0..]);
    }

    try writeContentLength(w, segmentedContentLength(res.body));

    if (send_body and res.body.len != 0) {
        try w.writeVecAll(res.body);
    }
}

/// Writes a stream response using HTTP chunked transfer encoding.
fn writeStream(
    w: *std.Io.Writer,
    res: StreamRes,
    keep_alive: bool,
    send_body: bool,
) !void {
    try writeStatusLine(w, res.status);

    const close_conn = (!keep_alive) or res.close;
    try w.writeAll(if (close_conn) "connection: close\r\n" else "connection: keep-alive\r\n");

    for (res.headers) |h| {
        var parts: HeaderLineParts = .{ h.name, ": ", h.value, "\r\n" };
        try w.writeVecAll(parts[0..]);
    }
    try w.writeAll("transfer-encoding: chunked\r\n\r\n");

    if (send_body) {
        var cw: ChunkedWriter = .{ .w = w };
        try res.body.writeFn(&cw);
        try cw.finish();
    }
}

/// Implements write upgrade.
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
    var line_buf: [128]u8 = undefined;
    var len: usize = 0;
    @memcpy(line_buf[len .. len + 9], "HTTP/1.1 ");
    len += 9;
    @memcpy(line_buf[len .. len + 3], &status_buf);
    len += 3;
    if (status.phrase()) |phrase| {
        line_buf[len] = ' ';
        len += 1;
        @memcpy(line_buf[len .. len + phrase.len], phrase);
        len += phrase.len;
    }
    @memcpy(line_buf[len .. len + 2], "\r\n");
    len += 2;
    try w.writeAll(line_buf[0..len]);
}

/// Writes the `content-length` header and header terminator.
fn writeContentLength(w: *std.Io.Writer, body_len: usize) !void {
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body_len}) catch unreachable;
    var line_buf: [64]u8 = undefined;
    var line_len: usize = 0;
    const prefix = "content-length: ";
    @memcpy(line_buf[line_len .. line_len + prefix.len], prefix);
    line_len += prefix.len;
    @memcpy(line_buf[line_len .. line_len + len_str.len], len_str);
    line_len += len_str.len;
    @memcpy(line_buf[line_len .. line_len + 4], "\r\n\r\n");
    line_len += 4;
    try w.writeAll(line_buf[0..line_len]);
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
    try writeAny(&w, res, true, true);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "content-length: 11\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out[0..w.end], "\r\nhello world"));
}

test "writeAny: stream body writes chunked encoding" {
    const S = struct {
        fn stream(cw: *ChunkedWriter) !void {
            try cw.writeAll("hello");
            try cw.writeAll("!");
        }
    };
    const res: StreamRes = .{
        .status = .ok,
        .body = .{ .writeFn = S.stream },
    };
    var out: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try writeAny(&w, res, true, true);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "transfer-encoding: chunked\r\n\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out[0..w.end], "5\r\nhello\r\n1\r\n!\r\n0\r\n\r\n"));
}

test "Response: maps supported body shapes" {
    try std.testing.expect(Response([]const u8) == Res);
    try std.testing.expect(Response([][]const u8) == SegmentedRes);
    try std.testing.expect(Response(BodyStream) == StreamRes);
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
