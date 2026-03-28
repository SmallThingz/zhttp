const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const parse = @import("../parse.zig");
const test_helpers = @import("test_helpers.zig");
const util = @import("util.zig");
const zstd = @import("libzstd");
const brotli = @import("libbrotli");

const flate = std.compress.flate;

/// Compression schemes supported by `Compression`.
pub const CompressionScheme = enum {
    /// Brotli content encoding.
    br,
    /// Zstandard content encoding.
    zstd,
    /// Gzip content encoding.
    gzip,
    /// Deflate (zlib wrapper) content encoding.
    deflate,
};

const NegotiatedSchemes = struct {
    items: [4]CompressionScheme = undefined,
    len: usize = 0,
};

fn qValue(params: []const u8) f32 {
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len < 2) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const k = std.mem.trim(u8, part[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(k, "q")) continue;
        const v = std.mem.trim(u8, part[eq + 1 ..], " \t");
        const q = std.fmt.parseFloat(f32, v) catch return 0.0;
        return std.math.clamp(q, 0.0, 1.0);
    }
    return 1.0;
}

fn schemeQuality(
    scheme: CompressionScheme,
    br_q: ?f32,
    zstd_q: ?f32,
    gzip_q: ?f32,
    deflate_q: ?f32,
    star_q: ?f32,
) f32 {
    return switch (scheme) {
        .br => br_q orelse star_q orelse 0.0,
        .zstd => zstd_q orelse star_q orelse 0.0,
        .gzip => gzip_q orelse star_q orelse 0.0,
        .deflate => deflate_q orelse star_q orelse 0.0,
    };
}

fn containsScheme(schemes: []const CompressionScheme, scheme: CompressionScheme) bool {
    for (schemes) |s| {
        if (s == scheme) return true;
    }
    return false;
}

fn negotiateEncodings(header_value: []const u8, allowed: []const CompressionScheme) NegotiatedSchemes {
    var br_q: ?f32 = null;
    var zstd_q: ?f32 = null;
    var gzip_q: ?f32 = null;
    var deflate_q: ?f32 = null;
    var star_q: ?f32 = null;

    var it = std.mem.splitScalar(u8, header_value, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;
        const semi = std.mem.indexOfScalar(u8, part, ';') orelse part.len;
        const token = std.mem.trim(u8, part[0..semi], " \t");
        const q = if (semi == part.len) 1.0 else qValue(part[semi + 1 ..]);

        if (std.ascii.eqlIgnoreCase(token, "br")) {
            br_q = q;
        } else if (std.ascii.eqlIgnoreCase(token, "zstd")) {
            zstd_q = q;
        } else if (std.ascii.eqlIgnoreCase(token, "gzip")) {
            gzip_q = q;
        } else if (std.ascii.eqlIgnoreCase(token, "deflate")) {
            deflate_q = q;
        } else if (std.ascii.eqlIgnoreCase(token, "*")) {
            star_q = q;
        }
    }

    var out: NegotiatedSchemes = .{};
    for (allowed) |scheme| {
        if (containsScheme(out.items[0..out.len], scheme)) continue;

        const q = schemeQuality(scheme, br_q, zstd_q, gzip_q, deflate_q, star_q);
        if (q <= 0.0) continue;

        var i = out.len;
        while (i > 0) : (i -= 1) {
            const prev = out.items[i - 1];
            const prev_q = schemeQuality(prev, br_q, zstd_q, gzip_q, deflate_q, star_q);
            if (q <= prev_q) break;
            out.items[i] = prev;
        }
        out.items[i] = scheme;
        out.len += 1;
    }
    return out;
}

fn compressFlate(
    allocator: std.mem.Allocator,
    body: []const u8,
    encoding: CompressionScheme,
    level: flate.Compress.Options,
) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, body.len + 64);
    errdefer out.deinit();

    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);

    const container: flate.Container = switch (encoding) {
        .gzip => .gzip,
        .deflate => .zlib,
        else => unreachable,
    };
    var comp = try flate.Compress.init(&out.writer, window, container, level);
    try comp.writer.writeAll(body);
    try comp.writer.flush();

    const list = out.toArrayList();
    return list.items;
}

fn compressForScheme(
    allocator: std.mem.Allocator,
    body: []const u8,
    scheme: CompressionScheme,
    opts: CompressionOptions,
) ![]u8 {
    return switch (scheme) {
        .br => brotli.compress(allocator, body, opts.brotli_options),
        .zstd => zstd.compress(allocator, body, opts.zstd_level),
        .gzip, .deflate => compressFlate(allocator, body, scheme, opts.level),
    };
}

/// Configuration for `Compression`.
pub const CompressionOptions = struct {
    /// Ordered whitelist of schemes the middleware is allowed to emit.
    ///
    /// This list also defines tie-break preference among equal `q` values and fallback order.
    schemes: []const CompressionScheme = &.{ .br, .zstd, .gzip, .deflate },
    /// Minimum uncompressed body size required before compression is attempted.
    min_size: usize = 256,
    /// Deflate/gzip compression level/options passed to `std.compress.flate`.
    level: flate.Compress.Options = flate.Compress.Options.default,
    /// Compression level used for zstd (`libzstd`).
    zstd_level: i32 = zstd.default_level,
    /// Compression options used for brotli (`libbrotli`).
    brotli_options: brotli.CompressOptions = .{},
    /// Behavior when `content-encoding` is already present on the response.
    ///
    /// Default asserts absence to keep the fast path branch-light and fail loudly on misuse.
    content_encoding_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `vary` is already present on the response.
    ///
    /// Use `check_then_add` when another middleware/handler may set `vary` first.
    vary_behavior: util.HeaderSetBehavior = .assert_absent,
};

/// Compresses response bodies when the client advertises a supported scheme.
///
/// Use this middleware to reduce response payload size/bandwidth for text-heavy responses.
pub fn Compression(comptime opts: CompressionOptions) type {
    const min_size: usize = opts.min_size;
    const allowed_schemes: []const CompressionScheme = opts.schemes;
    const content_encoding_behavior = opts.content_encoding_behavior;
    const vary_behavior = opts.vary_behavior;

    return struct {
        pub const Info = MiddlewareInfo{
            .name = "compression",
            .header = struct {
                /// Request `Accept-Encoding` capture used to decide scheme support.
                accept_encoding: parse.Optional(parse.String),
            },
        };

        /// Executes compression middleware for the current request.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            var res = try rctx.next(req);
            if (res.body.len < min_size) return res;
            if (!util.shouldAddHeader(res.headers, "content-encoding", content_encoding_behavior)) return res;

            const ae = req.header(.accept_encoding) orelse return res;
            const negotiated = negotiateEncodings(ae, allowed_schemes);
            if (negotiated.len == 0) return res;

            const a = req.allocator();
            var selected: ?CompressionScheme = null;
            var compressed: []u8 = undefined;
            for (negotiated.items[0..negotiated.len]) |scheme| {
                compressed = compressForScheme(a, res.body, scheme, opts) catch continue;
                selected = scheme;
                break;
            }
            const encoding = selected orelse return res;

            res.body = compressed;
            errdefer a.free(compressed);

            var hdrs: [2]Header = undefined;
            var n: usize = 0;
            hdrs[n] = .{
                .name = "content-encoding",
                .value = switch (encoding) {
                    .br => "br",
                    .zstd => "zstd",
                    .gzip => "gzip",
                    .deflate => "deflate",
                },
            };
            n += 1;
            if (util.shouldAddHeader(res.headers, "vary", vary_behavior)) {
                hdrs[n] = .{ .name = "vary", .value = "accept-encoding" };
                n += 1;
            }
            res.headers = try util.appendHeaders(a, res.headers, hdrs[0..n]);
            return res;
        }
    };
}

test "compression: negotiateEncodings honors q/wildcard and whitelist order" {
    var n = negotiateEncodings("br", &.{ .br, .gzip });
    try std.testing.expectEqual(@as(usize, 1), n.len);
    try std.testing.expectEqual(CompressionScheme.br, n.items[0]);

    n = negotiateEncodings("gzip;q=0, deflate", &.{ .gzip, .deflate, .br });
    try std.testing.expectEqual(@as(usize, 1), n.len);
    try std.testing.expectEqual(CompressionScheme.deflate, n.items[0]);

    n = negotiateEncodings("gzip;q=0.5, deflate;q=0.5", &.{ .gzip, .deflate });
    try std.testing.expectEqual(@as(usize, 2), n.len);
    try std.testing.expectEqual(CompressionScheme.gzip, n.items[0]);
    try std.testing.expectEqual(CompressionScheme.deflate, n.items[1]);

    n = negotiateEncodings("*;q=0.7, gzip;q=0, deflate;q=0.3", &.{ .br, .zstd, .gzip, .deflate });
    try std.testing.expectEqual(@as(usize, 3), n.len);
    try std.testing.expectEqual(CompressionScheme.br, n.items[0]);
    try std.testing.expectEqual(CompressionScheme.zstd, n.items[1]);
    try std.testing.expectEqual(CompressionScheme.deflate, n.items[2]);

    n = negotiateEncodings("*;q=0", &.{ .br, .zstd, .gzip, .deflate });
    try std.testing.expectEqual(@as(usize, 0), n.len);

    n = negotiateEncodings("br, gzip", &.{.gzip});
    try std.testing.expectEqual(@as(usize, 1), n.len);
    try std.testing.expectEqual(CompressionScheme.gzip, n.items[0]);
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
        /// Test helper next-handler implementation with pre-existing encoding.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{.{ .name = "content-encoding", .value = "br" }},
                .body = "hello",
            };
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
    defer reqv.deinit(a);
    var r = std.Io.Reader.fixed("Accept-Encoding: gzip\r\n\r\n");
    try reqv.parseHeaders(a, &r, 1024);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
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
        /// Test helper next-handler implementation with compressible payload.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{.{ .name = "vary", .value = "accept-encoding" }},
                .body = "hello",
            };
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
    defer reqv.deinit(a);
    var r = std.Io.Reader.fixed("Accept-Encoding: gzip\r\n\r\n");
    try reqv.parseHeaders(a, &r, 1024);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(usize, 2), res.headers.len);
    try std.testing.expectEqualStrings("content-encoding", res.headers[1].name);
}

test "compression: selects deflate when preferred" {
    const payload = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const Mw = Compression(.{ .min_size = 0 });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { accept_encoding: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        /// Test helper next-handler implementation with compressible payload.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{},
                .body = payload,
            };
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
    defer reqv.deinit(a);
    var r = std.Io.Reader.fixed("Accept-Encoding: gzip;q=0, deflate\r\n\r\n");
    try reqv.parseHeaders(a, &r, 1024);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(usize, 2), res.headers.len);
    try std.testing.expectEqualStrings("content-encoding", res.headers[0].name);
    try std.testing.expectEqualStrings("deflate", res.headers[0].value);
    try std.testing.expect(res.body.len > 2);
    try std.testing.expectEqual(@as(u8, 0x78), res.body[0]);
}

test "compression: selects gzip when preferred" {
    const payload = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    const Mw = Compression(.{ .min_size = 0 });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { accept_encoding: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        /// Test helper next-handler implementation with compressible payload.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{},
                .body = payload,
            };
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
    defer reqv.deinit(a);
    var r = std.Io.Reader.fixed("Accept-Encoding: gzip, deflate;q=0\r\n\r\n");
    try reqv.parseHeaders(a, &r, 1024);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqualStrings("gzip", res.headers[0].value);
    try std.testing.expect(res.body.len > 10);
    try std.testing.expectEqual(@as(u8, 0x1f), res.body[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), res.body[1]);
}

test "compression: selects brotli when preferred" {
    const payload = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const Mw = Compression(.{ .min_size = 0 });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { accept_encoding: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        /// Test helper next-handler implementation with compressible payload.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{},
                .body = payload,
            };
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
    defer reqv.deinit(a);
    var r = std.Io.Reader.fixed("Accept-Encoding: br, gzip;q=0.1\r\n\r\n");
    try reqv.parseHeaders(a, &r, 1024);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqualStrings("br", res.headers[0].value);
    const decoded = try brotli.decompress(a, res.body, payload.len * 2);
    try std.testing.expectEqualStrings(payload, decoded);
}

test "compression: selects zstd when preferred" {
    const payload = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const Mw = Compression(.{ .min_size = 0 });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { accept_encoding: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        /// Test helper next-handler implementation with compressible payload.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{},
                .body = payload,
            };
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
    defer reqv.deinit(a);
    var r = std.Io.Reader.fixed("Accept-Encoding: zstd;q=1, br;q=0\r\n\r\n");
    try reqv.parseHeaders(a, &r, 1024);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqualStrings("zstd", res.headers[0].value);
    const decoded = try zstd.decompress(a, res.body, payload.len * 2);
    try std.testing.expectEqualStrings(payload, decoded);
}

test "compression: whitelist disables schemes not in list" {
    const payload = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const Mw = Compression(.{
        .min_size = 0,
        .schemes = &.{.gzip},
    });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { accept_encoding: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        /// Test helper next-handler implementation with compressible payload.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{},
                .body = payload,
            };
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
    defer reqv.deinit(a);
    var r = std.Io.Reader.fixed("Accept-Encoding: br, gzip\r\n\r\n");
    try reqv.parseHeaders(a, &r, 1024);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqualStrings("gzip", res.headers[0].value);
}

test "compression: whitelist order controls tie-break preference" {
    const payload = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const Mw = Compression(.{
        .min_size = 0,
        .schemes = &.{ .gzip, .br },
    });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { accept_encoding: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        /// Test helper next-handler implementation with compressible payload.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{},
                .body = payload,
            };
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
    defer reqv.deinit(a);
    var r = std.Io.Reader.fixed("Accept-Encoding: br, gzip\r\n\r\n");
    try reqv.parseHeaders(a, &r, 1024);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqualStrings("gzip", res.headers[0].value);
}
