const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const parse = @import("../parse.zig");
const util = @import("util.zig");

const flate = std.compress.flate;

fn qIsZero(params: []const u8) bool {
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len < 2) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const k = std.mem.trim(u8, part[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(k, "q")) continue;
        const v = std.mem.trim(u8, part[eq + 1 ..], " \t");
        const q = std.fmt.parseFloat(f32, v) catch return false;
        return q == 0.0;
    }
    return false;
}

fn acceptsGzip(header_value: []const u8) bool {
    var it = std.mem.splitScalar(u8, header_value, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;
        const semi = std.mem.indexOfScalar(u8, part, ';') orelse part.len;
        const token = std.mem.trim(u8, part[0..semi], " \t");
        if (std.ascii.eqlIgnoreCase(token, "gzip") or std.ascii.eqlIgnoreCase(token, "*")) {
            if (semi == part.len) return true;
            if (!qIsZero(part[semi + 1 ..])) return true;
        }
    }
    return false;
}

pub fn Compression(comptime opts: anytype) type {
    const min_size: usize = if (@hasField(@TypeOf(opts), "min_size")) opts.min_size else 256;
    const level: flate.Compress.Options = if (@hasField(@TypeOf(opts), "level")) opts.level else flate.Compress.Options.default;

    return struct {
        pub const Needs = struct {
            pub const headers = struct {
                accept_encoding: parse.Optional(parse.String),
            };
        };

        pub fn call(comptime Next: type, next: Next, req: anytype) !Res {
            var res = try next.call(req);
            if (res.body.len < min_size) return res;
            if (util.hasHeader(res.headers, "content-encoding")) return res;

            const ae = req.header(.accept_encoding) orelse return res;
            if (!acceptsGzip(ae)) return res;

            const a = req.allocator();
            var out = try std.Io.Writer.Allocating.initCapacity(a, res.body.len + 64);
            const window = try a.alloc(u8, flate.max_window_len);
            var comp = try flate.Compress.init(&out.writer, window, .gzip, level);
            try comp.writer.writeAll(res.body);
            try comp.writer.flush();

            const list = out.toArrayList();
            const compressed = list.items;

            const extra_headers: []const Header = &.{
                .{ .name = "content-encoding", .value = "gzip" },
                .{ .name = "vary", .value = "accept-encoding" },
            };
            res.headers = try util.appendHeaders(a, res.headers, extra_headers);
            res.body = compressed;
            return res;
        }
    };
}

test "compression: acceptsGzip honors q=0" {
    try std.testing.expect(acceptsGzip("gzip"));
    try std.testing.expect(!acceptsGzip("gzip;q=0"));
    try std.testing.expect(acceptsGzip("br, gzip;q=0.5"));
    try std.testing.expect(acceptsGzip("*;q=0.1"));
}
