const std = @import("std");

const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const parse = @import("../parse.zig");
const util = @import("util.zig");

fn makeEtag(allocator: std.mem.Allocator, body: []const u8, weak: bool) ![]const u8 {
    const h = std.hash.Wyhash.hash(0, body);
    var tmp: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&tmp, "{x:0>16}", .{h}) catch unreachable;
    const extra: usize = if (weak) 4 else 2;
    const out = try allocator.alloc(u8, extra + hex.len);
    var i: usize = 0;
    if (weak) {
        out[i] = 'W';
        out[i + 1] = '/';
        i += 2;
    }
    out[i] = '"';
    i += 1;
    @memcpy(out[i .. i + hex.len], hex);
    i += hex.len;
    out[i] = '"';
    return out;
}

fn matchesIfNoneMatch(header_value: []const u8, tag: []const u8) bool {
    const trimmed = std.mem.trim(u8, header_value, " \t");
    if (std.mem.eql(u8, trimmed, "*")) return true;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, t, tag)) return true;
        if (t.len > 2 and t[0] == 'W' and t[1] == '/' and std.mem.eql(u8, t[2..], tag)) return true;
    }
    return false;
}

/// Configuration for `Etag`.
pub const EtagOptions = struct {
    /// Emit weak validators (`W/"..."`) instead of strong validators (`"..."`).
    weak: bool = false,
    /// Behavior when `etag` is already present on the response.
    ///
    /// Default asserts absence for strictness and lower overhead.
    header_behavior: util.HeaderSetBehavior = .assert_absent,
};

/// Adds an ETag header derived from the response body and supports `If-None-Match`.
///
/// Use this middleware to enable HTTP cache validation and efficient 304 responses.
pub fn Etag(comptime opts: EtagOptions) type {
    const weak: bool = opts.weak;
    const header_behavior = opts.header_behavior;

    return struct {
        pub const Info = MiddlewareInfo{
            .name = "etag",
            .header = struct {
                /// Conditional request header used for 304 matching.
                if_none_match: parse.Optional(parse.String),
            },
        };

        /// Executes etag middleware for the current request.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            var res = try rctx.next(req);
            if (res.body.len == 0) return res;
            if (!util.shouldAddHeader(res.headers, "etag", header_behavior)) return res;

            const tag = try makeEtag(req.allocator(), res.body, weak);
            if (req.header(.if_none_match)) |hdr| {
                if (matchesIfNoneMatch(hdr, tag)) {
                    return .{ .status = .not_modified, .headers = &.{.{ .name = "etag", .value = tag }}, .body = "" };
                }
            }

            res.headers = try util.appendHeaders(req.allocator(), res.headers, &.{.{ .name = "etag", .value = tag }});
            return res;
        }
    };
}

test "etag: matches if-none-match" {
    try std.testing.expect(matchesIfNoneMatch("\"abc\"", "\"abc\""));
    try std.testing.expect(matchesIfNoneMatch("W/\"abc\"", "\"abc\""));
    try std.testing.expect(matchesIfNoneMatch("*, W/\"nope\"", "\"abc\""));
    try std.testing.expect(!matchesIfNoneMatch("\"nope\"", "\"abc\""));
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

test "etag: check_then_add skips if already set" {
    const Mw = Etag(.{ .header_behavior = .check_then_add });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { if_none_match: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        /// Test helper next-handler implementation with pre-existing etag.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{.{ .name = "etag", .value = "\"user\"" }},
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

    const res = try runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(usize, 1), res.headers.len);
    try std.testing.expectEqualStrings("\"user\"", res.headers[0].value);
    try std.testing.expectEqualStrings("hello", res.body);
}
