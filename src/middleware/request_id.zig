const std = @import("std");

const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const test_helpers = @import("test_helpers.zig");
const util = @import("util.zig");

/// Configuration for `RequestId`.
pub const RequestIdOptions = struct {
    /// Response header name to emit the generated request identifier into.
    header: []const u8 = "x-request-id",
    /// Number of random bytes to generate before hex encoding.
    ///
    /// Final header value length is `bytes * 2`.
    bytes: usize = 16,
    /// Optional middleware context field name used to store the generated id buffer.
    ///
    /// When null, the middleware allocates a response-owned buffer per request.
    name: ?[]const u8 = null,
    /// Defines behavior when `header` already exists in the response.
    ///
    /// Default asserts absence for maximal speed and stricter contract checks.
    header_behavior: util.HeaderSetBehavior = .assert_absent,
};

/// Adds a request id response header using cryptographically random bytes from `req.io().random`.
///
/// Use this middleware for correlation across logs/services and debugging distributed requests.
pub fn RequestId(comptime opts: RequestIdOptions) type {
    const header_name: []const u8 = opts.header;
    const bytes: usize = opts.bytes;
    const store: bool = opts.name != null;
    const header_behavior = opts.header_behavior;
    const hex_len: usize = bytes * 2;

    const DataT = if (store) struct {
        /// Hex-encoded request id bytes reused across the request lifecycle.
        value: [hex_len]u8 = undefined,
    } else struct {};

    const Common = struct {
        pub const info_name: []const u8 = if (store) opts.name.? else "request_id";
        pub const Info = MiddlewareInfo{
            .name = info_name,
            .data = if (store) DataT else null,
        };

        fn handle(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            var res = try rctx.next(req);
            if (!util.shouldAddHeader(res.headers, header_name, header_behavior)) return res;

            var raw: [bytes]u8 = undefined;
            req.io().random(&raw);

            const a = req.allocator();
            var id_buf: []u8 = undefined;
            if (store) {
                id_buf = req.middlewareData(info_name).value[0..];
            } else {
                id_buf = try a.alloc(u8, hex_len);
            }
            const hex = std.fmt.bytesToHex(raw, .lower);
            @memcpy(id_buf[0..hex.len], hex[0..]);

            res.headers = try util.appendHeaders(a, res.headers, &.{.{ .name = header_name, .value = id_buf }});
            return res;
        }
    };

    return struct {
        pub const Info = Common.Info;
        /// Executes request-id middleware logic for the current request.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            return Common.handle(rctx, req);
        }
    };
}

test "request_id: adds header" {
    const Mw = RequestId(.{});
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

    const Next = struct {
        /// Test helper next-handler implementation.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return Res.text(200, "ok");
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
    const rid = test_helpers.headerValue(res.headers, "x-request-id") orelse return error.TestExpectedEqual;
    try std.testing.expect(rid.len == 32);
}

test "request_id: check_then_add keeps existing header" {
    const Mw = RequestId(.{ .header_behavior = .check_then_add });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

    const Next = struct {
        /// Test helper next-handler implementation with pre-existing header.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{.{ .name = "x-request-id", .value = "fixed-id" }},
                .body = "ok",
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
    try std.testing.expectEqualStrings("fixed-id", res.headers[0].value);
}
