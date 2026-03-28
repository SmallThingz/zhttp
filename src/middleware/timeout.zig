const std = @import("std");

const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;

const Io = std.Io;

pub fn Timeout(comptime opts: anytype) type {
    const clock: Io.Clock = if (@hasField(@TypeOf(opts), "clock")) opts.clock else .awake;
    const timeout: Io.Duration = if (@hasField(@TypeOf(opts), "duration"))
        opts.duration
    else if (@hasField(@TypeOf(opts), "ms"))
        Io.Duration.fromMilliseconds(opts.ms)
    else if (@hasField(@TypeOf(opts), "timeout_ms"))
        Io.Duration.fromMilliseconds(opts.timeout_ms)
    else
        @compileError("Timeout requires .duration or .ms/.timeout_ms");

    const store: bool = @hasField(@TypeOf(opts), "name");
    const DataT = if (store) struct {
        deadline: Io.Timestamp = .zero,
        timeout: Io.Duration = .zero,
        elapsed: Io.Duration = .zero,
        timed_out: bool = false,
    } else struct {};

    const Common = struct {
        pub const Data = DataT;
        pub const info_name: []const u8 = if (store) opts.name else "timeout";
        pub const Info = MiddlewareInfo{
            .name = info_name,
            .data = if (store) DataT else null,
        };

        fn handle(comptime rctx: anytype, req: rctx.T()) !Res {
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

    return if (store) struct {
        pub const Info = Common.Info;
        pub const Data = Common.Data;
        pub fn call(comptime rctx: anytype, req: rctx.T()) !Res {
            return Common.handle(rctx, req);
        }

        pub fn Override(comptime _: anytype) type {
            return struct {};
        }
    } else struct {
        pub const Info = Common.Info;
        pub const Data = Common.Data;
        pub fn call(comptime rctx: anytype, req: rctx.T()) !Res {
            return Common.handle(rctx, req);
        }

        pub fn Override(comptime _: anytype) type {
            return struct {};
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
