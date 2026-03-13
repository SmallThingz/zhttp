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
        /// If true, force a contiguous temp copy before writing.
        /// This is useful for 1:1 fairness in microbenchmarks (e.g. FaF-style memcpy path).
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
            if (!rp.copy) {
                for (rp.parts) |p| try w.writeAll(p);
                return;
            }

            var total: usize = 0;
            for (rp.parts) |p| total += p.len;

            // Copy directly into the Writer buffer (FaF-style "response buffer" memcpy).
            if (total <= (w.buffer.len - w.end)) {
                var off: usize = w.end;
                for (rp.parts) |p| {
                    @memcpy(w.buffer[off .. off + p.len], p);
                    off += p.len;
                }
                w.end = off;
                return;
            }

            try w.flush();
            if (total <= w.buffer.len) {
                var off: usize = 0;
                for (rp.parts) |p| {
                    @memcpy(w.buffer[off .. off + p.len], p);
                    off += p.len;
                }
                w.end = off;
                return;
            }

            // Fallback for unusually large responses.
            for (rp.parts) |p| try w.writeAll(p);
            return;
        }

        // HEAD: concatenate (up to 512) and emit only header bytes.
        var tmp: [512]u8 = undefined;
        var off: usize = 0;
        for (rp.parts) |p| {
            if (off + p.len > tmp.len) return error.WriteFailed;
            @memcpy(tmp[off .. off + p.len], p);
            off += p.len;
        }
        const raw = tmp[0..off];
        const end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
        const n = @min(raw.len, end + 4);
        try w.writeAll(raw[0..n]);
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
    const body_len: usize = if (send_body) res.body.len else res.body.len;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body_len}) catch unreachable;
    try w.writeAll("content-length: ");
    try w.writeAll(len_str);
    try w.writeAll("\r\n\r\n");

    if (send_body and res.body.len != 0) {
        try w.writeAll(res.body);
    }
}
