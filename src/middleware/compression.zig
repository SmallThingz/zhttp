const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
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

/// Configuration for `Compression`.
pub const CompressionOptions = struct {
    /// Minimum uncompressed body size required before compression is attempted.
    min_size: usize = 256,
    /// Deflate/gzip compression level/options passed to `std.compress.flate`.
    level: flate.Compress.Options = flate.Compress.Options.default,
    /// Behavior when `content-encoding` is already present on the response.
    ///
    /// Default asserts absence to keep the fast path branch-light and fail loudly on misuse.
    content_encoding_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `vary` is already present on the response.
    ///
    /// Use `check_then_add` when another middleware/handler may set `vary` first.
    vary_behavior: util.HeaderSetBehavior = .assert_absent,
};

/// Compresses response bodies with gzip when the client advertises support.
///
/// Use this middleware to reduce response payload size/bandwidth for text-heavy responses.
pub fn Compression(comptime opts: CompressionOptions) type {
    const min_size: usize = opts.min_size;
    const content_encoding_behavior = opts.content_encoding_behavior;
    const vary_behavior = opts.vary_behavior;

    return struct {
        pub const Info = MiddlewareInfo{
            .name = "compression",
            .header = struct {
                accept_encoding: parse.Optional(parse.String),
            },
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            var res = try rctx.next(req);
            if (res.body.len < min_size) return res;
            if (!util.shouldAddHeader(res.headers, "content-encoding", content_encoding_behavior)) return res;

            const ae = req.header(.accept_encoding) orelse return res;
            if (!acceptsGzip(ae)) return res;

            const a = req.allocator();
            var out = try std.Io.Writer.Allocating.initCapacity(a, res.body.len + 64);
            const window = try a.alloc(u8, flate.max_window_len);
            var comp = try flate.Compress.init(&out.writer, window, .gzip, opts.level);
            try comp.writer.writeAll(res.body);
            try comp.writer.flush();

            const list = out.toArrayList();
            const compressed = list.items;

            var hdrs: [2]Header = undefined;
            var n: usize = 0;
            hdrs[n] = .{ .name = "content-encoding", .value = "gzip" };
            n += 1;
            if (util.shouldAddHeader(res.headers, "vary", vary_behavior)) {
                hdrs[n] = .{ .name = "vary", .value = "accept-encoding" };
                n += 1;
            }
            res.headers = try util.appendHeaders(a, res.headers, hdrs[0..n]);
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

test "compression: check_then_add skips when content-encoding exists" {
    const Mw = Compression(.{ .min_size = 0, .content_encoding_behavior = .check_then_add });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { accept_encoding: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        pub fn call(_: @This(), _: anytype) !Res {
            return .{
                .status = .ok,
                .headers = &.{.{ .name = "content-encoding", .value = "br" }},
                .body = "hello",
            };
        }
    };

    const gpa = std.testing.allocator;
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = std.Io.Reader.fixed("Accept-Encoding: gzip\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 1024);

    const res = try Mw.call(Next, Next{}, &reqv);
    try std.testing.expectEqual(@as(usize, 1), res.headers.len);
    try std.testing.expectEqualStrings("br", res.headers[0].value);
    try std.testing.expectEqualStrings("hello", res.body);
}

test "compression: check_then_add skips duplicate vary" {
    const Mw = Compression(.{
        .min_size = 0,
        .vary_behavior = .check_then_add,
    });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { accept_encoding: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        pub fn call(_: @This(), _: anytype) !Res {
            return .{
                .status = .ok,
                .headers = &.{.{ .name = "vary", .value = "accept-encoding" }},
                .body = "hello",
            };
        }
    };

    const gpa = std.testing.allocator;
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = std.Io.Reader.fixed("Accept-Encoding: gzip\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 1024);

    const res = try Mw.call(Next, Next{}, &reqv);
    try std.testing.expectEqual(@as(usize, 2), res.headers.len);
    try std.testing.expectEqualStrings("content-encoding", res.headers[1].name);
}
