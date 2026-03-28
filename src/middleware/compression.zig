const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const parse = @import("../parse.zig");
const util = @import("util.zig");
const zstd = @import("zcompress");
const brotli = @import("libbrotli");

const flate = std.compress.flate;

const ContentEncoding = enum {
    br,
    zstd,
    gzip,
    deflate,
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

fn negotiateEncoding(header_value: []const u8) ?ContentEncoding {
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

    const br = br_q orelse star_q orelse 0.0;
    const zstd_qv = zstd_q orelse star_q orelse 0.0;
    const gzip = gzip_q orelse star_q orelse 0.0;
    const deflate = deflate_q orelse star_q orelse 0.0;

    var best_q: f32 = 0.0;
    var best: ?ContentEncoding = null;
    if (br > 0) {
        best = .br;
        best_q = br;
    }
    if (zstd_qv > best_q) {
        best = .zstd;
        best_q = zstd_qv;
    }
    if (gzip > best_q) {
        best = .gzip;
        best_q = gzip;
    }
    if (deflate > best_q) {
        best = .deflate;
    }

    return best;
}

fn compressFlate(
    allocator: std.mem.Allocator,
    body: []const u8,
    encoding: ContentEncoding,
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

fn runMiddlewareTest(
    comptime Mw: type,
    comptime ReqT: type,
    comptime Handler: type,
    reqv: *ReqT,
    method: []const u8,
) !Res {
    const rctx: ReqCtx = .{
        .handler = Handler,
        .middlewares = &.{Mw},
        .path = &.{},
        .query = &.{},
        .headers = &.{},
        .middleware_contexts = &.{},
        .idx = 0,
        ._base_req_type = ReqT,
    };
    const ReqW = rctx.T();
    const reqw: ReqW = .{
        ._base = reqv,
        .path = reqv.rawPath(),
        .method = method,
    };
    return rctx.run(reqw);
}

/// Configuration for `Compression`.
pub const CompressionOptions = struct {
    /// Minimum uncompressed body size required before compression is attempted.
    min_size: usize = 256,
    /// Deflate/gzip compression level/options passed to `std.compress.flate`.
    level: flate.Compress.Options = flate.Compress.Options.default,
    /// Compression level used for zstd (`zcompress`).
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

/// Compresses response bodies when the client advertises `gzip` or `deflate`.
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
                /// Request `Accept-Encoding` capture used to decide gzip support.
                accept_encoding: parse.Optional(parse.String),
            },
        };

        /// Executes compression middleware for the current request.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            var res = try rctx.next(req);
            if (res.body.len < min_size) return res;
            if (!util.shouldAddHeader(res.headers, "content-encoding", content_encoding_behavior)) return res;

            const ae = req.header(.accept_encoding) orelse return res;
            const encoding = negotiateEncoding(ae) orelse return res;

            const a = req.allocator();
            const compressed = switch (encoding) {
                .br => try brotli.compress(a, res.body, opts.brotli_options),
                .zstd => try zstd.compress(a, res.body, opts.zstd_level),
                .gzip, .deflate => try compressFlate(a, res.body, encoding, opts.level),
            };

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
            res.body = compressed;
            return res;
        }
    };
}

test "compression: negotiateEncoding honors q and wildcard precedence" {
    try std.testing.expectEqual(ContentEncoding.br, negotiateEncoding("br").?);
    try std.testing.expectEqual(ContentEncoding.zstd, negotiateEncoding("zstd").?);
    try std.testing.expectEqual(ContentEncoding.gzip, negotiateEncoding("gzip").?);
    try std.testing.expectEqual(ContentEncoding.deflate, negotiateEncoding("deflate").?);
    try std.testing.expectEqual(null, negotiateEncoding("gzip;q=0"));
    try std.testing.expectEqual(ContentEncoding.deflate, negotiateEncoding("gzip;q=0, deflate").?);
    try std.testing.expectEqual(ContentEncoding.gzip, negotiateEncoding("gzip;q=0.5, deflate;q=0.5").?);
    try std.testing.expectEqual(ContentEncoding.br, negotiateEncoding("*;q=0.1").?);
    try std.testing.expectEqual(ContentEncoding.br, negotiateEncoding("*;q=0.7, gzip;q=0, deflate;q=0.3").?);
    try std.testing.expectEqual(ContentEncoding.br, negotiateEncoding("br;q=0.5, gzip;q=0.5").?);
    try std.testing.expectEqual(ContentEncoding.zstd, negotiateEncoding("zstd;q=0.9, gzip;q=0.2").?);
    try std.testing.expectEqual(null, negotiateEncoding("*;q=0"));
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

    const res = try runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
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

    const res = try runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(usize, 2), res.headers.len);
    try std.testing.expectEqualStrings("content-encoding", res.headers[1].name);
}

test "compression: selects deflate when preferred" {
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
                .body = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
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

    const res = try runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(usize, 2), res.headers.len);
    try std.testing.expectEqualStrings("content-encoding", res.headers[0].name);
    try std.testing.expectEqualStrings("deflate", res.headers[0].value);
    try std.testing.expect(res.body.len > 2);
    try std.testing.expectEqual(@as(u8, 0x78), res.body[0]);
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

    const res = try runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
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

    const res = try runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqualStrings("zstd", res.headers[0].value);
    const decoded = try zstd.decompress(a, res.body, payload.len * 2);
    try std.testing.expectEqualStrings(payload, decoded);
}
