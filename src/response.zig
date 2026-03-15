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

    pub fn text(status: u16, body: []const u8) Res {
        return .{
            .status = status,
            .headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
            .body = body,
        };
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
    var status_buf: [3]u8 = undefined;
    const status_str = try std.fmt.bufPrint(&status_buf, "{d:0>3}", .{res.status});

    try w.writeAll("HTTP/1.1 ");
    try w.writeAll(status_str);
    try w.writeByte(' ');
    try w.writeAll(reasonPhrase(res.status));
    try w.writeAll("\r\n");

    const connection_line: []const u8 = if (keep_alive and !res.close)
        "connection: keep-alive\r\n"
    else
        "connection: close\r\n";
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
