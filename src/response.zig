const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Res = struct {
    status: u16 = 200,
    headers: []const Header = &.{},
    body: []const u8 = "",
    close: bool = false,
    raw: ?[]const u8 = null,
    raw_parts: ?RawParts = null,

    pub const RawParts = struct {
        /// Ordered pieces of the full HTTP response bytes (headers + optional body).
        parts: []const []const u8,
        /// If true, prefer a contiguous temp copy before writing (reserved).
        copy: bool = false,
    };

    pub fn text(status: u16, body: []const u8) Res {
        return .{
            .status = status,
            .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            .body = body,
        };
    }

    pub fn rawResponse(bytes: []const u8) Res {
        return .{ .raw = bytes };
    }

    pub fn rawParts(parts: []const []const u8) Res {
        return .{ .raw_parts = .{ .parts = parts } };
    }

    pub fn rawPartsCopy(parts: []const []const u8) Res {
        return .{ .raw_parts = .{ .parts = parts, .copy = true } };
    }
};

fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        414 => "URI Too Long",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "OK",
    };
}

pub fn write(
    w: *std.Io.Writer,
    res: Res,
    keep_alive: bool,
    send_body: bool,
) !void {
    if (res.raw_parts) |rp| {
        if (send_body) {
            if (rp.parts.len != 0) {
                const parts = @constCast(rp.parts);
                try w.writeVecAll(parts);
            }
            return;
        }

        // HEAD: stream until end of headers.
        var window: [4]u8 = undefined;
        var seen: usize = 0;
        for (rp.parts) |p| {
            for (p) |b| {
                try w.writeByte(b);
                if (seen < 4) {
                    window[seen] = b;
                    seen += 1;
                } else {
                    window[0] = window[1];
                    window[1] = window[2];
                    window[2] = window[3];
                    window[3] = b;
                }
                if (seen >= 4 and std.mem.eql(u8, window[0..], "\r\n\r\n")) {
                    return;
                }
            }
        }
        return;
    }

    if (res.raw) |raw| {
        if (send_body) {
            try w.writeAll(raw);
            return;
        }
        const end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
        const n = @min(raw.len, end + 4);
        try w.writeAll(raw[0..n]);
        return;
    }

    var status_buf: [3]u8 = undefined;
    const status_str = try std.fmt.bufPrint(&status_buf, "{d:0>3}", .{res.status});

    try w.writeAll("HTTP/1.1 ");
    try w.writeAll(status_str);
    try w.writeByte(' ');
    try w.writeAll(reasonPhrase(res.status));
    try w.writeAll("\r\n");

    const connection_value: []const u8 = if (keep_alive and !res.close) "keep-alive" else "close";
    try w.writeAll("connection: ");
    try w.writeAll(connection_value);
    try w.writeAll("\r\n");

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
    try w.writeAll("content-length: ");
    try w.writeAll(len_str);
    try w.writeAll("\r\n\r\n");

    if (send_body and res.body.len != 0) {
        try w.writeAll(res.body);
    }
}

test "rawPartsCopy matches raw bytes" {
    const base =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n";
    const date = "Date: Wed, 24 Feb 2021 12:00:00 GMT";
    const body = "Hello, World!";
    const res = Res.rawPartsCopy(&.{ base, date, "\r\n\r\n", body });

    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try write(&w, res, true, true);

    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "\r\n" ++
        "Hello, World!";
    try std.testing.expectEqualStrings(expected, out[0..w.end]);
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

test "write: raw_parts HEAD streams long headers" {
    const gpa = std.testing.allocator;
    const long_len: usize = 600;
    const long_value = try gpa.alloc(u8, long_len);
    defer gpa.free(long_value);
    @memset(long_value, 'a');

    const part1 = "HTTP/1.1 200 OK\r\nX-Long: ";
    const part3 = "\r\n\r\n";
    const body = "BODY";
    const res = Res.rawParts(&.{ part1, long_value, part3, body });

    const expected_len = part1.len + long_len + part3.len;
    const out = try gpa.alloc(u8, expected_len);
    defer gpa.free(out);
    var w = std.Io.Writer.fixed(out[0..]);
    try write(&w, res, true, false);

    try std.testing.expectEqual(expected_len, w.end);
    try std.testing.expectEqualSlices(u8, part1, out[0..part1.len]);
    try std.testing.expectEqualSlices(u8, long_value, out[part1.len .. part1.len + long_len]);
    try std.testing.expectEqualStrings("\r\n\r\n", out[expected_len - 4 .. expected_len]);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], body) == null);
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
