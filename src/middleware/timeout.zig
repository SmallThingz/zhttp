const std = @import("std");

const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;

const Io = std.Io;

/// Configuration for `Timeout`.
pub const TimeoutOptions = struct {
    /// Optional middleware context field name used to store deadline/elapsed/timed_out data.
    name: ?[]const u8 = null,
    /// Clock source used for deadline and elapsed-time calculations.
    clock: Io.Clock = .awake,
    /// Absolute timeout duration.
    ///
    /// If provided, this takes precedence over `ms` and `timeout_ms`.
    duration: ?Io.Duration = null,
    /// Timeout in milliseconds.
    ///
    /// Used only when `duration` is null.
    ms: ?i64 = null,
    /// Backward-compatible alias for `ms`.
    ///
    /// Used only when both `duration` and `ms` are null.
    timeout_ms: ?i64 = null,
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
    else if (opts.timeout_ms) |ms|
        Io.Duration.fromMilliseconds(ms)
    else
        @compileError("Timeout requires .duration or .ms/.timeout_ms");

    const store: bool = opts.name != null;
    const DataT = if (store) struct {
        deadline: Io.Timestamp = .zero,
        timeout: Io.Duration = .zero,
        elapsed: Io.Duration = .zero,
        timed_out: bool = false,
    } else struct {};

    const Common = struct {
        pub const Data = DataT;
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
        pub const Data = Common.Data;
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
        pub fn call(_: @This(), _: anytype) !Res {
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

    const res = try Mw.call(Next, Next{}, &reqv);
    try std.testing.expectEqual(@as(u16, 504), @intFromEnum(res.status));
}
