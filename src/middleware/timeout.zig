const std = @import("std");

const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const test_helpers = @import("test_helpers.zig");

const Io = std.Io;

/// Configuration for `Timeout`.
pub const TimeoutOptions = struct {
    /// Optional middleware context field name used to store deadline/elapsed/timed_out data.
    name: ?[]const u8 = null,
    /// Clock source used for deadline and elapsed-time calculations.
    clock: Io.Clock = .awake,
    /// Absolute timeout duration.
    ///
    /// If provided, this takes precedence over `ms`.
    duration: ?Io.Duration = null,
    /// Timeout in milliseconds.
    ///
    /// Used only when `duration` is null.
    ms: ?i64 = null,
};

/// Enforces a wall-clock request timeout around downstream middleware/handler execution.
///
/// Returns `504 timeout` when execution time exceeds the configured limit.
///
/// This is a cooperative timeout: once the timer fires, downstream execution
/// receives an `error.Canceled` request at its next `std.Io` cancelation
/// point. The timeout middleware waits for downstream cleanup before
/// returning, and closes the connection on timeout to avoid reusing a request
/// whose downstream path was interrupted mid-flight.
pub fn Timeout(comptime opts: TimeoutOptions) type {
    const clock: Io.Clock = opts.clock;
    const timeout: Io.Duration = if (opts.duration) |d|
        d
    else if (opts.ms) |ms|
        Io.Duration.fromMilliseconds(ms)
    else
        @compileError("Timeout requires .duration or .ms");

    const store: bool = opts.name != null;
    const DataT = if (store) struct {
        /// Computed request deadline timestamp.
        deadline: Io.Timestamp = .zero,
        /// Configured timeout duration.
        timeout: Io.Duration = .zero,
        /// Observed request processing duration.
        elapsed: Io.Duration = .zero,
        /// True when `elapsed` exceeded `timeout`.
        timed_out: bool = false,
    } else struct {};

    const Common = struct {
        pub const info_name: []const u8 = if (store) opts.name.? else "timeout";
        pub const Info = MiddlewareInfo{
            .name = info_name,
            .data = if (store) DataT else null,
        };
    };

    return struct {
        pub const Info = Common.Info;
        /// Executes timeout middleware for the current request.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            const start = Io.Timestamp.now(req.io(), clock);
            if (store) {
                const d = req.middlewareData(Common.info_name);
                d.deadline = start.addDuration(timeout);
                d.timeout = timeout;
            }

            const NextResult = @TypeOf(rctx.next(req));
            const Outcome = union(enum) {
                next: NextResult,
                timeout: Io.Cancelable!void,
            };
            const Worker = struct {
                fn runNext(child_req: @TypeOf(req)) @TypeOf(rctx.next(child_req)) {
                    return rctx.next(child_req);
                }

                fn runTimeout(io: Io) Io.Cancelable!void {
                    try Io.sleep(io, timeout, clock);
                }
            };

            var outcomes: [2]Outcome = undefined;
            var select = Io.Select(Outcome).init(req.io(), outcomes[0..]);
            try select.concurrent(.next, Worker.runNext, .{req});
            errdefer select.cancelDiscard();
            try select.concurrent(.timeout, Worker.runTimeout, .{req.io()});

            switch (try select.await()) {
                .next => |next_result| {
                    select.cancelDiscard();
                    const res = try next_result;
                    const elapsed = start.untilNow(req.io(), clock);

                    if (store) {
                        const d = req.middlewareData(Common.info_name);
                        d.elapsed = elapsed;
                        d.timed_out = false;
                    }

                    return res;
                },
                .timeout => |timeout_result| {
                    try timeout_result;

                    while (select.cancel()) |pending| {
                        switch (pending) {
                            .next => |next_result| {
                                _ = next_result catch {};
                            },
                            .timeout => |other_timeout| {
                                _ = other_timeout catch {};
                            },
                        }
                    }

                    const elapsed = start.untilNow(req.io(), clock);
                    if (store) {
                        const d = req.middlewareData(Common.info_name);
                        d.elapsed = elapsed;
                        d.timed_out = true;
                    }

                    var res = Res.text(504, "timeout");
                    res.close = true;
                    return res;
                },
            }
        }
    };
}

test "timeout: immediate timeout cancels downstream" {
    const Mw = Timeout(.{ .duration = std.Io.Duration.fromNanoseconds(-1) });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

    const Next = struct {
        /// Test helper next-handler implementation.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            try Io.sleep(req.io(), std.Io.Duration.fromMilliseconds(10), .awake);
            return Res.text(200, "late");
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

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(u16, 504), @intFromEnum(res.status));
}

test "timeout: named context stores deadline, timeout, and elapsed without timing out" {
    const Mw = Timeout(.{
        .name = "to",
        .duration = std.Io.Duration.fromMilliseconds(50),
        .ms = -1,
    });
    const MwCtx = struct {
        to: Mw.Info.data.?,
    };
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

    const Next = struct {
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return Res.text(200, "ok");
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
    const mw_ctx: MwCtx = .{ .to = .{} };
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));

    const data = reqv.middlewareDataConst(.to);
    try std.testing.expectEqual(std.Io.Duration.fromMilliseconds(50).nanoseconds, data.timeout.nanoseconds);
    try std.testing.expect(data.deadline.nanoseconds >= data.timeout.nanoseconds);
    try std.testing.expect(data.elapsed.nanoseconds >= 0);
    try std.testing.expect(!data.timed_out);
}

test "timeout: cooperatively cancels slow downstream io work" {
    const Mw = Timeout(.{
        .duration = std.Io.Duration.fromMilliseconds(1),
    });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

    const Next = struct {
        pub const function = call;
        var saw_canceled: bool = false;

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            saw_canceled = false;
            Io.sleep(req.io(), std.Io.Duration.fromMilliseconds(50), .awake) catch |err| switch (err) {
                error.Canceled => {
                    saw_canceled = true;
                    return err;
                },
            };
            return Res.text(200, "late");
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

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(u16, 504), @intFromEnum(res.status));
    try std.testing.expect(res.close);
    try std.testing.expect(Next.saw_canceled);
}
