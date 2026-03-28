const std = @import("std");

const Res = @import("../response.zig").Res;

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

        fn handle(comptime Next: type, next: Next, ctx: anytype, req: anytype, data_opt: ?*DataT) !Res {
            const start = Io.Timestamp.now(req.io(), clock);
            if (store) {
                if (data_opt) |d| {
                    d.deadline = start.addDuration(timeout);
                    d.timeout = timeout;
                }
            }

            const res = try next.call(ctx, req);
            const elapsed = start.untilNow(req.io(), clock);

            if (store) {
                if (data_opt) |d| {
                    d.elapsed = elapsed;
                    d.timed_out = elapsed.nanoseconds > timeout.nanoseconds;
                }
            }

            if (elapsed.nanoseconds > timeout.nanoseconds) {
                return Res.text(504, "timeout");
            }
            return res;
        }
    };

    return if (store) struct {
        pub const Data = Common.Data;
        pub const name = opts.name;
        pub fn call(comptime Next: type, next: Next, ctx: anytype, req: anytype, data: *DataT) !Res {
            return Common.handle(Next, next, ctx, req, data);
        }
    } else struct {
        pub const Data = Common.Data;
        pub fn call(comptime Next: type, next: Next, ctx: anytype, req: anytype) !Res {
            return Common.handle(Next, next, ctx, req, null);
        }
    };
}

test "timeout: immediate timeout" {
    const Mw = Timeout(.{ .duration = std.Io.Duration.fromNanoseconds(-1) });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

    const Next = struct {
        pub fn call(_: @This(), _: void, _: anytype) !Res {
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

    const res = try Mw.call(Next, Next{}, {}, &reqv);
    try std.testing.expectEqual(@as(u16, 504), @intFromEnum(res.status));
}
