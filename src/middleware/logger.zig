const std = @import("std");

const Res = @import("../response.zig").Res;

const Io = std.Io;

const LogState = struct {
    called: bool = false,
    method: []const u8 = "",
    path: []const u8 = "",
    status: u16 = 0,
};

var log_state: LogState = .{};

fn testLog(method: []const u8, path: []const u8, status: u16, _: Io.Duration) void {
    log_state.called = true;
    log_state.method = method;
    log_state.path = path;
    log_state.status = status;
}

pub fn Logger(comptime opts: anytype) type {
    const store: bool = @hasField(@TypeOf(opts), "name");
    const LogFn = *const fn ([]const u8, []const u8, u16, Io.Duration) void;
    const log_fn: ?LogFn = if (@hasField(@TypeOf(opts), "log")) opts.log else null;
    const clock: Io.Clock = if (@hasField(@TypeOf(opts), "clock")) opts.clock else .awake;

    const DataT = if (store) struct {
        start: Io.Timestamp = .zero,
        elapsed: Io.Duration = .zero,
        status: u16 = 0,
    } else struct {};

    const Common = struct {
        pub const Data = DataT;

        fn handle(comptime Next: type, next: Next, ctx: anytype, req: anytype, data_opt: ?*DataT) !Res {
            const start = Io.Timestamp.now(req.io(), clock);
            const res = try next.call(ctx, req);
            const elapsed = start.untilNow(req.io(), clock);

            if (store) {
                if (data_opt) |d| {
                    d.start = start;
                    d.elapsed = elapsed;
                    d.status = res.status;
                }
            }

            if (log_fn) |f| {
                @call(.auto, f, .{ req.method, req.baseConst().path_raw, @intFromEnum(res.status), elapsed });
            } else {
                const ms = elapsed.toMilliseconds();
                std.debug.print("{s} {s} {d} {d}ms\n", .{ req.method, req.baseConst().path_raw, res.status, ms });
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

test "logger: invokes log function" {
    log_state = .{};
    const Mw = Logger(.{ .log = testLog });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

    const Next = struct {
        pub fn call(_: @This(), _: void, _: anytype) !Res {
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

    const res = try Mw.call(Next, Next{}, {}, &reqv);
    try std.testing.expectEqual(@as(u16, 201), @intFromEnum(res.status));
    try std.testing.expect(log_state.called);
    try std.testing.expectEqualStrings("GET", log_state.method);
    try std.testing.expectEqualStrings("/x", log_state.path);
    try std.testing.expectEqual(@as(u16, 201), log_state.status);
}
