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

        fn handle(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            const start = Io.Timestamp.now(req.io(), clock);
            if (store) {
                const d = req.middlewareData(info_name);
                d.deadline = start.addDuration(timeout);
                d.timeout = timeout;
            }

            const res = try rctx.next(req);
            const elapsed = start.untilNow(req.io(), clock);

            if (store) {
                const d = req.middlewareData(info_name);
                d.elapsed = elapsed;
                d.timed_out = elapsed.nanoseconds > timeout.nanoseconds;
            }

            if (elapsed.nanoseconds > timeout.nanoseconds) {
                return Res.text(504, "timeout");
            }
            return res;
        }
    };

    return struct {
        pub const Info = Common.Info;
        /// Executes timeout middleware for the current request.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            return Common.handle(rctx, req);
        }
    };
}

test "timeout: immediate timeout" {
    const Mw = Timeout(.{ .duration = std.Io.Duration.fromNanoseconds(-1) });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

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
