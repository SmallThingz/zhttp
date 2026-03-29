const std = @import("std");

const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const parse = @import("../parse.zig");
const test_helpers = @import("test_helpers.zig");
const util = @import("util.zig");

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

            const tag = try util.makeEtag(req.allocator(), res.body, weak);
            if (req.header(.if_none_match)) |hdr| {
                if (util.matchesIfNoneMatch(hdr, tag)) {
                    return .{ .status = .not_modified, .headers = &.{.{ .name = "etag", .value = tag }}, .body = "" };
                }
            }

            res.headers = try util.appendHeaders(req.allocator(), res.headers, &.{.{ .name = "etag", .value = tag }});
            return res;
        }
    };
}

test "etag: matches if-none-match" {
    try std.testing.expect(util.matchesIfNoneMatch("\"abc\"", "\"abc\""));
    try std.testing.expect(util.matchesIfNoneMatch("W/\"abc\"", "\"abc\""));
    try std.testing.expect(util.matchesIfNoneMatch("*, W/\"nope\"", "\"abc\""));
    try std.testing.expect(!util.matchesIfNoneMatch("\"nope\"", "\"abc\""));
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

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(usize, 1), res.headers.len);
    try std.testing.expectEqualStrings("\"user\"", res.headers[0].value);
    try std.testing.expectEqualStrings("hello", res.body);
}

test "etag: weak mode emits weak tags and empty bodies stay untouched" {
    const WeakMw = Etag(.{ .weak = true });
    const ReqT = @import("../request.zig").Request(
        struct { if_none_match: parse.Optional(parse.String) },
        struct {},
        &.{},
        struct {},
    );

    const WeakNext = struct {
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{},
                .body = "hello",
            };
        }
    };

    const EmptyNext = struct {
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{},
                .body = "",
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

    {
        var reqv = ReqT.init(a, std.testing.io, line, .{});
        defer reqv.deinit(a);
        const res = try test_helpers.runMiddlewareTest(WeakMw, ReqT, WeakNext, &reqv, line.method);
        try std.testing.expectEqual(@as(usize, 1), res.headers.len);
        try std.testing.expect(std.mem.startsWith(u8, res.headers[0].value, "W/\""));
    }

    {
        var reqv = ReqT.init(a, std.testing.io, line, .{});
        defer reqv.deinit(a);
        const res = try test_helpers.runMiddlewareTest(WeakMw, ReqT, EmptyNext, &reqv, line.method);
        try std.testing.expectEqual(@as(usize, 0), res.headers.len);
        try std.testing.expectEqualStrings("", res.body);
    }
}
