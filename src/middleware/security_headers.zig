const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const util = @import("util.zig");

/// Configuration for `SecurityHeaders`.
pub const SecurityHeadersOptions = struct {
    /// Value for `x-content-type-options`; set null to disable emission.
    x_content_type_options: ?[]const u8 = "nosniff",
    /// Value for `x-frame-options`; set null to disable emission.
    x_frame_options: ?[]const u8 = "DENY",
    /// Value for `referrer-policy`; set null to disable emission.
    referrer_policy: ?[]const u8 = "no-referrer",
    /// Value for `content-security-policy`; set null to disable emission.
    content_security_policy: ?[]const u8 = null,
    /// Value for `permissions-policy`; set null to disable emission.
    permissions_policy: ?[]const u8 = null,
    /// Value for `strict-transport-security`; set null to disable emission.
    strict_transport_security: ?[]const u8 = null,
    /// Value for `cross-origin-embedder-policy`; set null to disable emission.
    cross_origin_embedder_policy: ?[]const u8 = null,
    /// Value for `cross-origin-opener-policy`; set null to disable emission.
    cross_origin_opener_policy: ?[]const u8 = null,
    /// Value for `cross-origin-resource-policy`; set null to disable emission.
    cross_origin_resource_policy: ?[]const u8 = null,
    /// Behavior when `x-content-type-options` already exists.
    x_content_type_options_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `x-frame-options` already exists.
    x_frame_options_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `referrer-policy` already exists.
    referrer_policy_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `content-security-policy` already exists.
    content_security_policy_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `permissions-policy` already exists.
    permissions_policy_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `strict-transport-security` already exists.
    strict_transport_security_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `cross-origin-embedder-policy` already exists.
    cross_origin_embedder_policy_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `cross-origin-opener-policy` already exists.
    cross_origin_opener_policy_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `cross-origin-resource-policy` already exists.
    cross_origin_resource_policy_behavior: util.HeaderSetBehavior = .assert_absent,
};

/// Appends common hardening headers to responses.
///
/// Use this middleware to centralize browser security policy defaults for your app.
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
    const x_content_type_options_behavior = opts.x_content_type_options_behavior;
    const x_frame_options_behavior = opts.x_frame_options_behavior;
    const referrer_policy_behavior = opts.referrer_policy_behavior;
    const content_security_policy_behavior = opts.content_security_policy_behavior;
    const permissions_policy_behavior = opts.permissions_policy_behavior;
    const strict_transport_security_behavior = opts.strict_transport_security_behavior;
    const cross_origin_embedder_policy_behavior = opts.cross_origin_embedder_policy_behavior;
    const cross_origin_opener_policy_behavior = opts.cross_origin_opener_policy_behavior;
    const cross_origin_resource_policy_behavior = opts.cross_origin_resource_policy_behavior;

    return struct {
        pub const Info = MiddlewareInfo{
            .name = "security_headers",
        };

        /// Executes security-header middleware for the current request.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            var res = try rctx.next(req);
            const a = req.allocator();

            var hdrs: [9]Header = undefined;
            var n: usize = 0;

            if (x_content_type_options) |v| if (util.shouldAddHeader(res.headers, "x-content-type-options", x_content_type_options_behavior)) {
                hdrs[n] = .{ .name = "x-content-type-options", .value = v };
                n += 1;
            };
            if (x_frame_options) |v| if (util.shouldAddHeader(res.headers, "x-frame-options", x_frame_options_behavior)) {
                hdrs[n] = .{ .name = "x-frame-options", .value = v };
                n += 1;
            };
            if (referrer_policy) |v| if (util.shouldAddHeader(res.headers, "referrer-policy", referrer_policy_behavior)) {
                hdrs[n] = .{ .name = "referrer-policy", .value = v };
                n += 1;
            };
            if (csp) |v| if (util.shouldAddHeader(res.headers, "content-security-policy", content_security_policy_behavior)) {
                hdrs[n] = .{ .name = "content-security-policy", .value = v };
                n += 1;
            };
            if (permissions_policy) |v| if (util.shouldAddHeader(res.headers, "permissions-policy", permissions_policy_behavior)) {
                hdrs[n] = .{ .name = "permissions-policy", .value = v };
                n += 1;
            };
            if (hsts) |v| if (util.shouldAddHeader(res.headers, "strict-transport-security", strict_transport_security_behavior)) {
                hdrs[n] = .{ .name = "strict-transport-security", .value = v };
                n += 1;
            };
            if (coep) |v| if (util.shouldAddHeader(res.headers, "cross-origin-embedder-policy", cross_origin_embedder_policy_behavior)) {
                hdrs[n] = .{ .name = "cross-origin-embedder-policy", .value = v };
                n += 1;
            };
            if (coop) |v| if (util.shouldAddHeader(res.headers, "cross-origin-opener-policy", cross_origin_opener_policy_behavior)) {
                hdrs[n] = .{ .name = "cross-origin-opener-policy", .value = v };
                n += 1;
            };
            if (corp) |v| if (util.shouldAddHeader(res.headers, "cross-origin-resource-policy", cross_origin_resource_policy_behavior)) {
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

fn countHeader(headers: []const Header, name: []const u8) usize {
    var n: usize = 0;
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) n += 1;
    }
    return n;
}

test "security_headers: default headers present" {
    const Mw = SecurityHeaders(.{});
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

    const Next = struct {
        /// Test helper next-handler implementation.
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

test "security_headers: check_then_add skips existing" {
    const Mw = SecurityHeaders(.{ .x_frame_options_behavior = .check_then_add });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {}, struct {}, &.{}, MwCtx);

    const Next = struct {
        /// Test helper next-handler implementation with pre-existing headers.
        pub fn call(_: @This(), _: anytype) !Res {
            return .{
                .status = .ok,
                .headers = &.{.{ .name = "x-frame-options", .value = "SAMEORIGIN" }},
                .body = "ok",
            };
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
    try std.testing.expectEqual(@as(usize, 1), countHeader(res.headers, "x-frame-options"));
    try std.testing.expect(hasHeader(res.headers, "x-content-type-options"));
}
