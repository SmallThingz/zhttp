const std = @import("std");

const Header = @import("../response.zig").Header;
const Res = @import("../response.zig").Res;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const util = @import("util.zig");
const core_util = @import("../util.zig");

/// Returns the first header value for `name` using case-insensitive matching.
pub fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (core_util.asciiEqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Counts matching headers for `name` using case-insensitive matching.
pub fn countHeader(headers: []const Header, name: []const u8) usize {
    var n: usize = 0;
    for (headers) |h| {
        if (core_util.asciiEqlIgnoreCase(h.name, name)) n += 1;
    }
    return n;
}

/// Returns whether `headers` contains `name` (case-insensitive).
pub fn hasHeader(headers: []const Header, name: []const u8) bool {
    return util.hasHeader(headers, name);
}

/// Runs a single middleware test flow with a synthetic request wrapper.
pub fn runMiddlewareTest(
    comptime Mw: type,
    comptime ReqT: type,
    comptime Handler: type,
    reqv: *ReqT,
    method: []const u8,
) !Res {
    const rctx: ReqCtx = .{
        .handler = Handler,
        .middlewares = &.{Mw},
        .path = &.{},
        .query = &.{},
        .headers = &.{},
        .middleware_contexts = &.{},
        .idx = 0,
        ._base_req_type = ReqT,
    };
    const ReqW = rctx.T();
    const reqw: ReqW = .{
        ._base = reqv,
        .path = ReqT.path,
        .method = method,
    };
    return rctx.run(reqw);
}

test "test_helpers: header lookup and counting are case-insensitive" {
    const headers = [_]Header{
        .{ .name = "X-Test", .value = "1" },
        .{ .name = "x-test", .value = "2" },
    };

    try std.testing.expectEqualStrings("1", headerValue(headers[0..], "x-test").?);
    try std.testing.expectEqual(@as(usize, 2), countHeader(headers[0..], "X-TEST"));
    try std.testing.expect(hasHeader(headers[0..], "x-test"));
}
