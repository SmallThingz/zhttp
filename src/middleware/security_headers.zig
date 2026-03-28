const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const util = @import("util.zig");

pub const SecurityHeadersOptions = struct {
    x_content_type_options: ?[]const u8 = "nosniff",
    x_frame_options: ?[]const u8 = "DENY",
    referrer_policy: ?[]const u8 = "no-referrer",
    content_security_policy: ?[]const u8 = null,
    permissions_policy: ?[]const u8 = null,
    strict_transport_security: ?[]const u8 = null,
    cross_origin_embedder_policy: ?[]const u8 = null,
    cross_origin_opener_policy: ?[]const u8 = null,
    cross_origin_resource_policy: ?[]const u8 = null,
};

pub fn SecurityHeaders(comptime opts: SecurityHeadersOptions) type {
    const x_content_type_options: ?[]const u8 = opts.x_content_type_options;
    const x_frame_options: ?[]const u8 = opts.x_frame_options;
    const referrer_policy: ?[]const u8 = opts.referrer_policy;
    const csp: ?[]const u8 = opts.content_security_policy;
    const permissions_policy: ?[]const u8 = opts.permissions_policy;
    const hsts: ?[]const u8 = opts.strict_transport_security;
    const coep: ?[]const u8 = opts.cross_origin_embedder_policy;
    const coop: ?[]const u8 = opts.cross_origin_opener_policy;
    const corp: ?[]const u8 = opts.cross_origin_resource_policy;

    return struct {
        pub const Info = MiddlewareInfo{
            .name = "security_headers",
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            var res = try rctx.next(req);
            const a = req.allocator();

            var hdrs: [9]Header = undefined;
            var n: usize = 0;

            if (x_content_type_options) |v| if (!util.hasHeader(res.headers, "x-content-type-options")) {
                hdrs[n] = .{ .name = "x-content-type-options", .value = v };
                n += 1;
            };
            if (x_frame_options) |v| if (!util.hasHeader(res.headers, "x-frame-options")) {
                hdrs[n] = .{ .name = "x-frame-options", .value = v };
                n += 1;
            };
            if (referrer_policy) |v| if (!util.hasHeader(res.headers, "referrer-policy")) {
                hdrs[n] = .{ .name = "referrer-policy", .value = v };
                n += 1;
            };
            if (csp) |v| if (!util.hasHeader(res.headers, "content-security-policy")) {
                hdrs[n] = .{ .name = "content-security-policy", .value = v };
                n += 1;
            };
            if (permissions_policy) |v| if (!util.hasHeader(res.headers, "permissions-policy")) {
                hdrs[n] = .{ .name = "permissions-policy", .value = v };
                n += 1;
            };
            if (hsts) |v| if (!util.hasHeader(res.headers, "strict-transport-security")) {
                hdrs[n] = .{ .name = "strict-transport-security", .value = v };
                n += 1;
            };
            if (coep) |v| if (!util.hasHeader(res.headers, "cross-origin-embedder-policy")) {
                hdrs[n] = .{ .name = "cross-origin-embedder-policy", .value = v };
                n += 1;
            };
            if (coop) |v| if (!util.hasHeader(res.headers, "cross-origin-opener-policy")) {
                hdrs[n] = .{ .name = "cross-origin-opener-policy", .value = v };
                n += 1;
            };
            if (corp) |v| if (!util.hasHeader(res.headers, "cross-origin-resource-policy")) {
                hdrs[n] = .{ .name = "cross-origin-resource-policy", .value = v };
                n += 1;
            };

            if (n == 0) return res;
            res.headers = try util.appendHeaders(a, res.headers, hdrs[0..n]);
            return res;
        }
    };
}

fn hasHeader(headers: []const Header, name: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}

test "security_headers: default headers present" {
    const Mw = SecurityHeaders(.{});
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
    try std.testing.expect(hasHeader(res.headers, "x-content-type-options"));
    try std.testing.expect(hasHeader(res.headers, "x-frame-options"));
    try std.testing.expect(hasHeader(res.headers, "referrer-policy"));
}
