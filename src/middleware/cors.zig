const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const parse = @import("../parse.zig");
const test_helpers = @import("test_helpers.zig");
const util = @import("util.zig");

pub const CorsSignature = struct {};

fn listContainsIgnoreCase(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(item, value)) return true;
    }
    return false;
}

fn parseHeaderList(value: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var parts = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len != 0) try parts.append(allocator, t);
    }
    return parts.toOwnedSlice(allocator);
}

fn allocHeaders(allocator: std.mem.Allocator, src: []const Header) ![]const Header {
    if (src.len == 0) return &.{};
    const out = try allocator.alloc(Header, src.len);
    @memcpy(out, src);
    return out;
}

/// Configuration for `Cors`.
pub const CorsOptions = struct {
    /// Allowed origins for CORS.
    ///
    /// Use `"*"` to allow any origin. Empty means deny all cross-origin requests.
    origins: []const []const u8 = &.{},
    /// Allowed request methods for preflight validation.
    ///
    /// Use `"*"` to allow any method.
    methods: []const []const u8 = &.{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" },
    /// Allowed request headers for preflight validation.
    ///
    /// Null reflects requested headers; list restricts to explicit set; `"*"` allows any.
    headers: ?[]const []const u8 = null,
    /// Response headers exposed to browsers via `access-control-expose-headers`.
    expose: []const []const u8 = &.{},
    /// Whether to emit `access-control-allow-credentials: true`.
    credentials: bool = false,
    /// Optional `access-control-max-age` preflight cache duration in seconds.
    max_age: ?u32 = null,
    /// When true, reject disallowed simple requests with `403` instead of passing through.
    enforce: bool = false,
    /// Optional middleware context field name used to store origin/allow/preflight results.
    name: ?[]const u8 = null,
    /// Optional custom origin predicate.
    ///
    /// When provided, this overrides static `origins` matching logic.
    origin_is_allowed: ?*const fn ([]const u8) bool = null,
    /// Behavior when `access-control-allow-origin` already exists.
    allow_origin_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `access-control-allow-credentials` already exists.
    allow_credentials_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `access-control-allow-headers` already exists.
    allow_headers_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `access-control-allow-methods` already exists.
    allow_methods_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `access-control-max-age` already exists.
    max_age_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `access-control-expose-headers` already exists.
    expose_headers_behavior: util.HeaderSetBehavior = .assert_absent,
    /// Behavior when `vary` already exists.
    vary_behavior: util.HeaderSetBehavior = .assert_absent,
};

/// Implements CORS preflight handling and simple-response header injection.
///
/// Use this middleware when browsers access your API from different origins.
pub fn Cors(comptime opts: CorsOptions) type {
    const origins: []const []const u8 = opts.origins;
    const methods: []const []const u8 = opts.methods;
    const allow_headers_opt: ?[]const []const u8 = opts.headers;
    const expose_headers: []const []const u8 = opts.expose;
    const allow_credentials: bool = opts.credentials;
    const max_age: ?u32 = opts.max_age;
    const enforce: bool = opts.enforce;
    const store: bool = opts.name != null;
    const origin_is_allowed = opts.origin_is_allowed;
    const allow_origin_behavior = opts.allow_origin_behavior;
    const allow_credentials_behavior = opts.allow_credentials_behavior;
    const allow_headers_behavior = opts.allow_headers_behavior;
    const allow_methods_behavior = opts.allow_methods_behavior;
    const max_age_behavior = opts.max_age_behavior;
    const expose_headers_behavior = opts.expose_headers_behavior;
    const vary_behavior = opts.vary_behavior;

    const allow_any_origin: bool = comptime blk: {
        for (origins) |o| {
            if (std.mem.eql(u8, o, "*")) break :blk true;
        }
        break :blk false;
    };

    const allow_any_method: bool = comptime blk: {
        for (methods) |m| {
            if (std.mem.eql(u8, m, "*")) break :blk true;
        }
        break :blk false;
    };

    const allow_any_header: bool = comptime blk: {
        if (allow_headers_opt) |hs| {
            for (hs) |h| {
                if (std.mem.eql(u8, h, "*")) break :blk true;
            }
        }
        break :blk false;
    };

    const DataT = if (store) struct {
        /// Stores `origin`.
        origin: []const u8 = "",
        /// Stores `allowed`.
        allowed: bool = false,
        /// Stores `preflight`.
        preflight: bool = false,
    } else struct {};

    const Common = struct {
        pub const Signature = CorsSignature;
        pub const info_name: []const u8 = if (store) opts.name.? else "cors";
        pub const Info = MiddlewareInfo{
            .name = info_name,
            .data = if (store) DataT else null,
            .header = struct {
                /// Stores `origin`.
                origin: parse.Optional(parse.String),
                /// Stores `access_control_request_method`.
                access_control_request_method: parse.Optional(parse.String),
                /// Stores `access_control_request_headers`.
                access_control_request_headers: parse.Optional(parse.String),
            },
        };

        fn originAllowed(origin: []const u8) bool {
            if (origin_is_allowed) |f| return @call(.auto, f, .{origin});
            if (allow_any_origin) return true;
            for (origins) |o| {
                if (std.mem.eql(u8, o, origin)) return true;
            }
            return false;
        }

        fn methodAllowed(method: []const u8) bool {
            if (allow_any_method) return true;
            return listContainsIgnoreCase(methods, method);
        }

        fn headersAllowed(requested: []const []const u8) bool {
            if (allow_headers_opt == null) return true;
            if (allow_any_header) return true;
            const allowed = allow_headers_opt.?;
            for (requested) |h| {
                if (!listContainsIgnoreCase(allowed, h)) return false;
            }
            return true;
        }

        fn varyHeaderValue(preflight: bool) []const u8 {
            return if (preflight)
                "origin, access-control-request-method, access-control-request-headers"
            else
                "origin";
        }

        fn appendCorsHeaders(allocator: std.mem.Allocator, base: []const Header, extra: []const Header) ![]const Header {
            return util.appendHeaders(allocator, base, extra);
        }

        fn handle(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            const origin_opt = req.header(.origin) orelse return rctx.next(req);
            const origin = origin_opt;
            const needs_origin_copy = store or !(allow_any_origin and !allow_credentials);
            const origin_copy = if (needs_origin_copy) try req.allocator().dupe(u8, origin) else origin;
            const allowed = originAllowed(origin);

            const is_options = std.ascii.eqlIgnoreCase(req.method, "OPTIONS");
            const preflight = is_options and req.header(.access_control_request_method) != null;

            if (store) {
                const d = req.middlewareData(info_name);
                d.* = .{
                    .origin = origin_copy,
                    .allowed = allowed,
                    .preflight = preflight,
                };
            }

            if (preflight) {
                if (!allowed) return Res.text(403, "cors forbidden");
                const req_method = req.header(.access_control_request_method).?;
                if (!methodAllowed(req_method)) return Res.text(403, "cors forbidden");

                var requested_headers: []const []const u8 = &.{};
                if (req.header(.access_control_request_headers)) |h| {
                    requested_headers = try parseHeaderList(h, req.allocator());
                    if (!headersAllowed(requested_headers)) return Res.text(403, "cors forbidden");
                }

                var hdrs: [6]Header = undefined;
                var n: usize = 0;

                const origin_value = if (allow_any_origin and !allow_credentials) "*" else origin_copy;
                if (util.shouldAddHeader(hdrs[0..n], "access-control-allow-origin", allow_origin_behavior)) {
                    hdrs[n] = .{ .name = "access-control-allow-origin", .value = origin_value };
                    n += 1;
                }

                if (allow_credentials) {
                    if (util.shouldAddHeader(hdrs[0..n], "access-control-allow-credentials", allow_credentials_behavior)) {
                        hdrs[n] = .{ .name = "access-control-allow-credentials", .value = "true" };
                        n += 1;
                    }
                }

                if (allow_headers_opt) |allowed_headers| {
                    const value = try util.joinCommaList(req.allocator(), allowed_headers);
                    if (value.len != 0) {
                        if (util.shouldAddHeader(hdrs[0..n], "access-control-allow-headers", allow_headers_behavior)) {
                            hdrs[n] = .{ .name = "access-control-allow-headers", .value = value };
                            n += 1;
                        }
                    }
                } else if (requested_headers.len != 0) {
                    const value = try util.joinCommaList(req.allocator(), requested_headers);
                    if (util.shouldAddHeader(hdrs[0..n], "access-control-allow-headers", allow_headers_behavior)) {
                        hdrs[n] = .{ .name = "access-control-allow-headers", .value = value };
                        n += 1;
                    }
                }

                const methods_value = try util.joinCommaList(req.allocator(), methods);
                if (util.shouldAddHeader(hdrs[0..n], "access-control-allow-methods", allow_methods_behavior)) {
                    hdrs[n] = .{ .name = "access-control-allow-methods", .value = methods_value };
                    n += 1;
                }

                if (max_age) |age| {
                    const value = try std.fmt.allocPrint(req.allocator(), "{d}", .{age});
                    if (util.shouldAddHeader(hdrs[0..n], "access-control-max-age", max_age_behavior)) {
                        hdrs[n] = .{ .name = "access-control-max-age", .value = value };
                        n += 1;
                    }
                }

                if (util.shouldAddHeader(hdrs[0..n], "vary", vary_behavior)) {
                    hdrs[n] = .{ .name = "vary", .value = varyHeaderValue(true) };
                    n += 1;
                }

                const headers = try allocHeaders(req.allocator(), hdrs[0..n]);
                return .{ .status = .no_content, .headers = headers, .body = "" };
            }

            if (!allowed) {
                if (enforce) return Res.text(403, "cors forbidden");
                return rctx.next(req);
            }

            var res = try rctx.next(req);

            const origin_value = if (allow_any_origin and !allow_credentials) "*" else origin_copy;
            var hdrs: [4]Header = undefined;
            var n: usize = 0;
            if (util.shouldAddHeader(res.headers, "access-control-allow-origin", allow_origin_behavior)) {
                hdrs[n] = .{ .name = "access-control-allow-origin", .value = origin_value };
                n += 1;
            }
            if (allow_credentials) {
                if (util.shouldAddHeader(res.headers, "access-control-allow-credentials", allow_credentials_behavior)) {
                    hdrs[n] = .{ .name = "access-control-allow-credentials", .value = "true" };
                    n += 1;
                }
            }
            if (expose_headers.len != 0) {
                const value = try util.joinCommaList(req.allocator(), expose_headers);
                if (value.len != 0) {
                    if (util.shouldAddHeader(res.headers, "access-control-expose-headers", expose_headers_behavior)) {
                        hdrs[n] = .{ .name = "access-control-expose-headers", .value = value };
                        n += 1;
                    }
                }
            }
            if (!(allow_any_origin and !allow_credentials)) {
                if (util.shouldAddHeader(res.headers, "vary", vary_behavior)) {
                    hdrs[n] = .{ .name = "vary", .value = varyHeaderValue(false) };
                    n += 1;
                }
            }

            if (n == 0) return res;
            res.headers = try appendCorsHeaders(req.allocator(), res.headers, hdrs[0..n]);
            return res;
        }
    };

    return struct {
        pub const Signature = Common.Signature;
        pub const Info = Common.Info;
        /// Handles a middleware invocation for the current request context.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            return Common.handle(rctx, req);
        }
    };
}

test "cors: preflight and simple request" {
    const Mw = Cors(.{ .origins = &.{"https://example.com"} });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct {
            origin: parse.Optional(parse.String),
            access_control_request_method: parse.Optional(parse.String),
            access_control_request_headers: parse.Optional(parse.String),
        },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        /// Handles a middleware invocation for the current request context.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return Res.text(200, "ok");
        }
    };

    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const path_buf = "/any".*;
        const query_buf: [0]u8 = .{};
        const line: @import("../request.zig").RequestLine = .{
            .method = "OPTIONS",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
        defer reqv.deinit(a);
        var r = std.Io.Reader.fixed("Origin: https://example.com\r\nAccess-Control-Request-Method: POST\r\n\r\n");
        try reqv.parseHeaders(a, &r, 1024);

        const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
        try std.testing.expectEqual(@as(u16, 204), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("https://example.com", test_helpers.headerValue(res.headers, "access-control-allow-origin").?);
    }

    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const path_buf = "/any".*;
        const query_buf: [0]u8 = .{};
        const line: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
        defer reqv.deinit(a);
        var r = std.Io.Reader.fixed("Origin: https://example.com\r\n\r\n");
        try reqv.parseHeaders(a, &r, 1024);

        const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
        try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("https://example.com", test_helpers.headerValue(res.headers, "access-control-allow-origin").?);
    }
}

test "cors: check_then_add skips existing response headers" {
    const Mw = Cors(.{
        .origins = &.{"https://example.com"},
        .allow_origin_behavior = .check_then_add,
        .vary_behavior = .check_then_add,
    });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct {
            origin: parse.Optional(parse.String),
            access_control_request_method: parse.Optional(parse.String),
            access_control_request_headers: parse.Optional(parse.String),
        },
        struct {},
        &.{},
        MwCtx,
    );

    const Next = struct {
        /// Handles a middleware invocation for the current request context.
        pub const function = call;
        pub fn call(comptime rctx: ReqCtx, _: rctx.T()) !Res {
            return .{
                .status = .ok,
                .headers = &.{
                    .{ .name = "access-control-allow-origin", .value = "https://example.com" },
                    .{ .name = "vary", .value = "origin" },
                },
                .body = "ok",
            };
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path_buf = "/any".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(a, std.testing.io, line, mw_ctx);
    defer reqv.deinit(a);
    var r = std.Io.Reader.fixed("Origin: https://example.com\r\n\r\n");
    try reqv.parseHeaders(a, &r, 1024);

    const res = try test_helpers.runMiddlewareTest(Mw, ReqT, Next, &reqv, line.method);
    try std.testing.expectEqual(@as(usize, 1), test_helpers.countHeader(res.headers, "access-control-allow-origin"));
    try std.testing.expectEqual(@as(usize, 1), test_helpers.countHeader(res.headers, "vary"));
}
