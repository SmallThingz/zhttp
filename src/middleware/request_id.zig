const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const util = @import("util.zig");

pub fn RequestId(comptime opts: anytype) type {
    const header_name: []const u8 = if (@hasField(@TypeOf(opts), "header")) opts.header else "x-request-id";
    const bytes: usize = if (@hasField(@TypeOf(opts), "bytes")) opts.bytes else 16;
    const store: bool = @hasField(@TypeOf(opts), "name");
    const hex_len: usize = bytes * 2;

    const DataT = if (store) struct {
        value: [hex_len]u8 = undefined,
    } else struct {};

    const Common = struct {
        pub const Data = DataT;
        pub const info_name: []const u8 = if (store) opts.name else "request_id";
        pub const Info = MiddlewareInfo{
            .name = info_name,
            .data = if (store) DataT else null,
        };

        fn handle(comptime rctx: anytype, req: rctx.T()) !Res {
            var res = try rctx.next(req);
            if (util.hasHeader(res.headers, header_name)) return res;

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

fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

test "request_id: adds header" {
    const Mw = RequestId(.{});
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
    const rid = headerValue(res.headers, "x-request-id") orelse return error.TestExpectedEqual;
    try std.testing.expect(rid.len == 32);
}
