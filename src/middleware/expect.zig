const std = @import("std");

const parse = @import("../parse.zig");
const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const request = @import("../request.zig");
const test_helpers = @import("test_helpers.zig");
const util = @import("../util.zig");

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
    /// When false (default), `Expect: 100-continue` is rejected for requests
    /// that do not advertise a readable request body.
    /// `Content-Length: 0` is treated as no body.
    ///
    /// Set true to accept `Expect: 100-continue` even when no body is present.
    allow_without_body: bool = false,
};

const ExpectState = struct {
    /// True when `Expect: 100-continue` has been accepted for this request.
    approved: bool = false,
    /// True once interim `100 Continue` has already been emitted.
    sent: bool = false,
};

fn is100Continue(value: []const u8) bool {
    return util.asciiEqlLower(std.mem.trim(u8, value, " \t"), "100-continue");
}

fn framingHasReadableBody(framing: anytype) bool {
    return switch (framing) {
        .chunked, .content_length => true,
        .none, .content_length_zero => false,
    };
}

/// Validates request `Expect` header and enables `100 Continue` body-read handling.
///
/// - Missing `Expect` header: pass-through.
/// - `Expect: 100-continue`: by default requires a readable request body; when
///   accepted, first body read/discard emits interim `100 Continue`.
/// - Any other value: returns `417` and closes the connection.
pub fn Expect(comptime opts: ExpectOptions) type {
    const reject_status: u16 = opts.status;
    const reject_body: []const u8 = opts.body;
    const info_name: []const u8 = opts.name orelse "expect";
    const allow_without_body: bool = opts.allow_without_body;

    return struct {
        pub const Info = MiddlewareInfo{
            .name = info_name,
            .data = ExpectState,
            .header = struct {
                /// Captured request `Expect` header value.
                expect: parse.Optional(parse.String),
            },
        };

        fn reject(comptime ReqT: type, req: ReqT) Res {
            const base = req.baseMut();
            base.body = .none;
            var res = Res.text(reject_status, reject_body);
            res.close = true;
            return res;
        }

        fn hasFramedBody(base: anytype) bool {
            return switch (base.body) {
                .none => false,
                .chunked => true,
                .content_length => |remaining| remaining != 0,
                .downloaded => |downloaded| downloaded.bytes.len != 0 or framingHasReadableBody(downloaded.framing),
                .discarded, .streamed => |framing| framingHasReadableBody(framing),
                .errored => |failed| framingHasReadableBody(failed.framing),
            };
        }

        /// Executes Expect-header validation for the current request.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            const state = req.middlewareData(info_name);
            state.approved = false;
            state.sent = false;
            const expect_value = req.header(.expect) orelse return rctx.next(req);
            const base = req.baseMut();
            if (is100Continue(expect_value)) {
                if (!allow_without_body and !hasFramedBody(base)) {
                    return reject(@TypeOf(req), req);
                }
                state.approved = true;
                return rctx.next(req);
            }

            return reject(@TypeOf(req), req);
        }

        /// Overrides request body readers to emit interim `100 Continue` once.
        pub fn Override(comptime rctx: ReqCtx) type {
            return struct {
                fn sendContinueIfNeeded(req: *rctx.T()) void {
                    const state = req.middlewareData(info_name);
                    if (!state.approved or state.sent) return;

                    const base = req.baseMut();
                    switch (base.body) {
                        .none => return,
                        .content_length => |remaining| if (remaining == 0) return,
                        .chunked => {},
                        .downloaded, .discarded, .streamed, .errored => return,
                    }

                    const w = req.raw().writer();
                    w.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch return;
                    w.flush() catch return;
                    state.sent = true;
                }

                pub fn bodyAll(req: *rctx.T(), max_bytes: usize) @TypeOf(req.bodyAll(max_bytes)) {
                    sendContinueIfNeeded(req);
                    return req.bodyAll(max_bytes);
                }

                pub fn discardUnreadBody(req: *rctx.T()) @TypeOf(req.discardUnreadBody()) {
                    sendContinueIfNeeded(req);
                    return req.discardUnreadBody();
                }

                pub fn bodyReader(req: *rctx.T()) @TypeOf(req.bodyReader()) {
                    sendContinueIfNeeded(req);
                    return req.bodyReader();
                }
            };
        }
    };
}

const ExpectTestReq = request.Request(
    struct {
        /// Captured request `Expect` header value.
        expect: parse.Optional(parse.String),
    },
    struct {},
    &.{},
    struct { expect: ExpectState },
);

fn initExpectTestReq(method: []const u8) ExpectTestReq {
    const line: request.RequestLine = .{
        .method = @constCast(method),
        .version = .http11,
        .path = @constCast("/"[0..]),
        .query = @constCast(""[0..]),
    };
    return ExpectTestReq.init(std.testing.allocator, std.testing.io, line, .{ .expect = .{} });
}

const ExpectNextOk = struct {
    pub const function = call;
    pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
        return Res.text(200, "ok");
    }
};

test "expect middleware: missing header passes through" {
    const Mw = Expect(.{});
    var reqv = initExpectTestReq("POST");
    defer reqv.deinit(std.testing.allocator);
    const res = try test_helpers.runMiddlewareTest(Mw, ExpectTestReq, ExpectNextOk, &reqv, "POST");
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
    try std.testing.expect(!reqv.middlewareDataConst("expect").approved);
    try std.testing.expect(!reqv.middlewareDataConst("expect").sent);
}

test "expect middleware: accepts 100-continue and marks request approved" {
    const Mw = Expect(.{});
    var reqv = initExpectTestReq("POST");
    defer reqv.deinit(std.testing.allocator);
    reqv.base().body = .{ .content_length = 1 };
    reqv.headersMut().expect = .{
        .present = true,
        .inner = .{ .value = "100-CONTINUE" },
    };

    const res = try test_helpers.runMiddlewareTest(Mw, ExpectTestReq, ExpectNextOk, &reqv, "POST");
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
    try std.testing.expect(reqv.middlewareDataConst("expect").approved);
    try std.testing.expect(!reqv.middlewareDataConst("expect").sent);
}

test "expect middleware: rejects 100-continue when body is absent by default" {
    const Mw = Expect(.{});
    var reqv = initExpectTestReq("GET");
    defer reqv.deinit(std.testing.allocator);
    reqv.headersMut().expect = .{
        .present = true,
        .inner = .{ .value = "100-continue" },
    };

    const res = try test_helpers.runMiddlewareTest(Mw, ExpectTestReq, ExpectNextOk, &reqv, "GET");
    try std.testing.expectEqual(@as(u16, 417), @intFromEnum(res.status));
    try std.testing.expect(res.close);
    try std.testing.expect(!reqv.middlewareDataConst("expect").approved);
}

test "expect middleware: permissive mode allows 100-continue without body" {
    const Mw = Expect(.{ .allow_without_body = true });
    var reqv = initExpectTestReq("GET");
    defer reqv.deinit(std.testing.allocator);
    reqv.headersMut().expect = .{
        .present = true,
        .inner = .{ .value = "100-continue" },
    };

    const res = try test_helpers.runMiddlewareTest(Mw, ExpectTestReq, ExpectNextOk, &reqv, "GET");
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
    try std.testing.expect(reqv.middlewareDataConst("expect").approved);
}

test "expect middleware: rejects 100-continue with content-length zero by default" {
    const Mw = Expect(.{});
    var reqv = initExpectTestReq("POST");
    defer reqv.deinit(std.testing.allocator);
    reqv.base().body = .{ .content_length = 0 };
    reqv.headersMut().expect = .{
        .present = true,
        .inner = .{ .value = "100-continue" },
    };

    const res = try test_helpers.runMiddlewareTest(Mw, ExpectTestReq, ExpectNextOk, &reqv, "POST");
    try std.testing.expectEqual(@as(u16, 417), @intFromEnum(res.status));
    try std.testing.expect(res.close);
    try std.testing.expect(!reqv.middlewareDataConst("expect").approved);
    try std.testing.expect(!reqv.middlewareDataConst("expect").sent);
}

test "expect middleware: accepts drained non-empty content-length body" {
    const Mw = Expect(.{});
    var reqv = initExpectTestReq("POST");
    defer reqv.deinit(std.testing.allocator);
    reqv.base().body = .{ .discarded = .content_length };
    reqv.headersMut().expect = .{
        .present = true,
        .inner = .{ .value = "100-continue" },
    };

    const res = try test_helpers.runMiddlewareTest(Mw, ExpectTestReq, ExpectNextOk, &reqv, "POST");
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
    try std.testing.expect(reqv.middlewareDataConst("expect").approved);
    try std.testing.expect(!reqv.middlewareDataConst("expect").sent);
}

test "expect middleware: rejects unsupported expectation with close" {
    const Mw = Expect(.{});
    var reqv = initExpectTestReq("POST");
    defer reqv.deinit(std.testing.allocator);
    reqv.headersMut().expect = .{
        .present = true,
        .inner = .{ .value = "magic-thing" },
    };

    const res = try test_helpers.runMiddlewareTest(Mw, ExpectTestReq, ExpectNextOk, &reqv, "POST");
    try std.testing.expectEqual(@as(u16, 417), @intFromEnum(res.status));
    try std.testing.expect(res.close);
    try std.testing.expectEqualStrings("expectation failed\n", res.body);
}

test "expect middleware: trims linear whitespace around 100-continue token" {
    const Mw = Expect(.{});
    var reqv = initExpectTestReq("POST");
    defer reqv.deinit(std.testing.allocator);
    reqv.base().body = .{ .content_length = 1 };
    reqv.headersMut().expect = .{
        .present = true,
        .inner = .{ .value = " \t100-continue\t " },
    };

    const res = try test_helpers.runMiddlewareTest(Mw, ExpectTestReq, ExpectNextOk, &reqv, "POST");
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
    try std.testing.expect(reqv.middlewareDataConst("expect").approved);
}
