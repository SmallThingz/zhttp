const std = @import("std");

const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const test_helpers = @import("test_helpers.zig");

const Io = std.Io;

const LogState = struct {
    /// Whether the test logger callback was invoked.
    called: bool = false,
    /// Captured request method for assertion.
    method: []const u8 = "",
    /// Captured request path for assertion.
    path: []const u8 = "",
    /// Captured response status code for assertion.
    status: u16 = 0,
};

var log_state: LogState = .{};

fn testLog(method: []const u8, path: []const u8, status: u16, _: Io.Duration) void {
    log_state.called = true;
    log_state.method = method;
    log_state.path = path;
    log_state.status = status;
}

/// Configuration for `Logger`.
pub const LoggerOptions = struct {
    /// Optional middleware context field name used to store timing/status data.
    ///
    /// When null, logger still logs but does not store per-request data in `req.middlewareData(...)`.
    name: ?[]const u8 = null,
    /// Optional custom sink invoked once per request with method, path, status and elapsed duration.
    ///
    /// When null, logger writes to stderr via `std.debug.print`.
    log: ?*const fn ([]const u8, []const u8, u16, Io.Duration) void = null,
    /// Clock source used for request latency measurement.
    ///
    /// Use `.monotonic` or another clock when you need timing semantics different from `.awake`.
    clock: Io.Clock = .awake,
};

/// Logs request method/path/status and latency for each request.
///
/// Use this middleware for observability in development and production.
/// Optionally stores measured values in middleware context for downstream handlers.
pub fn Logger(comptime opts: LoggerOptions) type {
    const store: bool = opts.name != null;
    const LogFn = *const fn ([]const u8, []const u8, u16, Io.Duration) void;
    const log_fn: ?LogFn = opts.log;
    const clock: Io.Clock = opts.clock;

    const DataT = if (store) struct {
        /// Timestamp captured immediately before downstream execution.
        start: Io.Timestamp = .zero,
        /// Measured downstream execution duration.
        elapsed: Io.Duration = .zero,
        /// Downstream response status code.
        status: u16 = 0,
    } else struct {};

    const Common = struct {
        pub const info_name: []const u8 = if (store) opts.name.? else "logger";
        pub const Info = MiddlewareInfo{
            .name = info_name,
            .data = if (store) DataT else null,
        };

        fn handle(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            const start = Io.Timestamp.now(req.io(), clock);
            const res = try rctx.next(req);
            const elapsed = start.untilNow(req.io(), clock);

            if (store) {
                const d = req.middlewareData(info_name);
                d.start = start;
                d.elapsed = elapsed;
                d.status = @intFromEnum(res.status);
            }

            if (log_fn) |f| {
                @call(.auto, f, .{ req.method, req.rawPath(), @intFromEnum(res.status), elapsed });
            } else {
                const ms = elapsed.toMilliseconds();
                std.debug.print("{s} {s} {d} {d}ms\n", .{ req.method, req.rawPath(), res.status, ms });
            }
            return res;
        }
    };

    return struct {
        pub const Info = Common.Info;
        /// Executes logger middleware for the current request.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            return Common.handle(rctx, req);
        }
    };
}

test "logger: invokes log function" {
    log_state = .{};
    const Mw = Logger(.{ .log = testLog });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

    const Next = struct {
        /// Test helper next-handler implementation.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return Res.text(201, "ok");
        }
    };

    const gpa = std.testing.allocator;
    const path_buf = "/x".*;
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
    try std.testing.expectEqual(@as(u16, 201), @intFromEnum(res.status));
    try std.testing.expect(log_state.called);
    try std.testing.expectEqualStrings("GET", log_state.method);
    try std.testing.expectEqualStrings("/x", log_state.path);
    try std.testing.expectEqual(@as(u16, 201), log_state.status);
}
