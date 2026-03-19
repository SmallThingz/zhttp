const std = @import("std");
const builtin = @import("builtin");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Res = struct {
    status: std.http.Status = .ok,
    headers: []const Header = &.{},
    body: []const u8 = "",
    close: bool = false,

    pub fn text(status: u16, body: []const u8) Res {
        return .{
            .status = @enumFromInt(status),
            .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            .body = body,
        };
    }
};

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
    try writeStatusLine(w, res.status);

    const connection_line: []const u8 = if (keep_alive and !res.close) "connection: keep-alive\r\n" else "connection: close\r\n";
    try w.writeAll(connection_line);

    // Application-provided headers.
    for (res.headers) |h| {
        try w.writeAll(h.name);
        try w.writeAll(": ");
        try w.writeAll(h.value);
        try w.writeAll("\r\n");
    }

    // Always emit Content-Length (no chunked responses for now).
    var len_buf: [32]u8 = undefined;
    const body_len: usize = res.body.len;
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

    if (send_body and res.body.len != 0) {
        try w.writeAll(res.body);
    }
}

pub fn writeUpgrade(w: *std.Io.Writer, res: Res) !void {
    try writeStatusLine(w, res.status);

    for (res.headers) |h| {
        try w.writeAll(h.name);
        try w.writeAll(": ");
        try w.writeAll(h.value);
        try w.writeAll("\r\n");
    }

    try w.writeAll("\r\n");
}

fn writeStatusLine(w: *std.Io.Writer, status: std.http.Status) !void {
    const status_code: u16 = @intCast(@intFromEnum(status));
    var status_buf: [3]u8 = undefined;
    status_buf[1..3].* = digits2(@intCast(status_code % 100));
    status_buf[0] = @intCast('0' + (status_code / 100) % 10);

    try w.writeAll("HTTP/1.1 ");
    try w.writeAll(&status_buf);
    if (status.phrase()) |phrase| {
        try w.writeAll(" ");
        try w.writeAll(phrase);
    }
    try w.writeAll("\r\n");
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
