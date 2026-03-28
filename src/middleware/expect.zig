const std = @import("std");

const parse = @import("../parse.zig");
const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const test_helpers = @import("test_helpers.zig");

/// Configuration for `Expect`.
pub const ExpectOptions = struct {
    /// Optional middleware context field name.
    ///
    /// Defaults to `"expect"`.
    name: ?[]const u8 = null,
    /// Status returned when `Expect` contains an unsupported value.
    status: u16 = 417,
    /// Body returned when `Expect` contains an unsupported value.
    body: []const u8 = "expectation failed\n",
};

fn is100Continue(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "100-continue");
}

/// Validates request `Expect` header and enables `100 Continue` body-read handling.
///
/// - Missing `Expect` header: pass-through.
/// - `Expect: 100-continue`: marks the request as approved; first body read/discard emits interim `100 Continue`.
/// - Any other value: returns `417` and closes the connection.
pub fn Expect(comptime opts: ExpectOptions) type {
    const reject_status: u16 = opts.status;
    const reject_body: []const u8 = opts.body;
    const info_name: []const u8 = opts.name orelse "expect";

    return struct {
        pub const Info = MiddlewareInfo{
            .name = info_name,
            .header = struct {
                /// Captured request `Expect` header value.
                expect: parse.Optional(parse.String),
            },
        };

        /// Executes Expect-header validation for the current request.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            const expect_value = req.header(.expect) orelse return rctx.next(req);
            if (is100Continue(expect_value)) {
                req.raw().approveExpectContinue();
                return rctx.next(req);
            }

            const base = req.baseMut();
            base.body_kind = .none;
            base.body_remaining = 0;
            var res = Res.text(reject_status, reject_body);
            res.close = true;
            return res;
        }
    };
}

test "expect middleware: missing header passes through" {
    const Mw = Expect(.{});
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {
        /// Captured request `Expect` header value.
        expect: parse.Optional(parse.String),
    }, struct {}, &.{}, MwCtx);

    const Next = struct {
        /// Test helper next-handler implementation.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return Res.text(200, "ok");
        }
    };

    const gpa = std.testing.allocator;
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "POST",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
    try std.testing.expect(!reqv.baseConst().expect_continue_approved);
}

test "expect middleware: accepts 100-continue and marks request approved" {
    const Mw = Expect(.{});
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {
        /// Captured request `Expect` header value.
        expect: parse.Optional(parse.String),
    }, struct {}, &.{}, MwCtx);

    const Next = struct {
        /// Test helper next-handler implementation.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return Res.text(200, "ok");
        }
    };

    const gpa = std.testing.allocator;
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "POST",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    reqv.headersMut().expect = .{
        .present = true,
        .inner = .{ .value = "100-CONTINUE" },
    };

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
    try std.testing.expect(reqv.baseConst().expect_continue_approved);
}

test "expect middleware: rejects unsupported expectation with close" {
    const Mw = Expect(.{});
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {
        /// Captured request `Expect` header value.
        expect: parse.Optional(parse.String),
    }, struct {}, &.{}, MwCtx);

    const Next = struct {
        /// Test helper next-handler implementation.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return Res.text(200, "ok");
        }
    };

    const gpa = std.testing.allocator;
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "POST",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    reqv.headersMut().expect = .{
        .present = true,
        .inner = .{ .value = "magic-thing" },
    };

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(u16, 417), @intFromEnum(res.status));
    try std.testing.expect(res.close);
    try std.testing.expectEqualStrings("expectation failed\n", res.body);
}
