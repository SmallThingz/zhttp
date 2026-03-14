const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const parse = @import("../parse.zig");
const router = @import("../router.zig");
const util = @import("util.zig");

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

pub fn Cors(comptime opts: anytype) type {
    const origins: []const []const u8 = if (@hasField(@TypeOf(opts), "origins")) opts.origins else &.{};
    const methods: []const []const u8 = if (@hasField(@TypeOf(opts), "methods")) opts.methods else &.{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS" };
    const allow_headers_opt: ?[]const []const u8 = if (@hasField(@TypeOf(opts), "headers")) opts.headers else null;
    const expose_headers: []const []const u8 = if (@hasField(@TypeOf(opts), "expose")) opts.expose else &.{};
    const allow_credentials: bool = if (@hasField(@TypeOf(opts), "credentials")) opts.credentials else false;
    const max_age: ?u32 = if (@hasField(@TypeOf(opts), "max_age")) opts.max_age else null;
    const enforce: bool = if (@hasField(@TypeOf(opts), "enforce")) opts.enforce else false;
    const register_routes_opt: bool = if (@hasField(@TypeOf(opts), "register_routes")) opts.register_routes else true;
    const store: bool = @hasField(@TypeOf(opts), "name");
    const origin_is_allowed = if (@hasField(@TypeOf(opts), "origin_is_allowed")) opts.origin_is_allowed else null;

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
        origin: []const u8 = "",
        allowed: bool = false,
        preflight: bool = false,
    } else struct {};

    const Common = struct {
        pub const Needs = struct {
            pub const headers = struct {
                origin: parse.Optional(parse.String),
                access_control_request_method: parse.Optional(parse.String),
                access_control_request_headers: parse.Optional(parse.String),
            };
        };

        pub const register_routes = register_routes_opt;
        pub const Routes = .{
            router.options("/*", defaultOptionsHandler, .{}),
        };

        pub const Data = DataT;

        fn defaultOptionsHandler(req: anytype) !Res {
            _ = req;
            return Res.text(404, "not found");
        }

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

        fn handle(comptime Next: type, next: Next, ctx: anytype, req: anytype, data_opt: ?*DataT) !Res {
            const origin_opt = req.header(.origin) orelse return next.call(ctx, req);
            const origin = origin_opt;
            const needs_origin_copy = store or !(allow_any_origin and !allow_credentials);
            const origin_copy = if (needs_origin_copy) try req.allocator().dupe(u8, origin) else origin;
            const allowed = originAllowed(origin);

            const is_options = std.ascii.eqlIgnoreCase(req.method, "OPTIONS");
            const preflight = is_options and req.header(.access_control_request_method) != null;

            if (store) {
                if (data_opt) |d| {
                    d.* = .{
                        .origin = origin_copy,
                        .allowed = allowed,
                        .preflight = preflight,
                    };
                }
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
                hdrs[n] = .{ .name = "access-control-allow-origin", .value = origin_value };
                n += 1;

                if (allow_credentials) {
                    hdrs[n] = .{ .name = "access-control-allow-credentials", .value = "true" };
                    n += 1;
                }

                if (allow_headers_opt) |allowed_headers| {
                    const value = try util.joinCommaList(req.allocator(), allowed_headers);
                    if (value.len != 0) {
                        hdrs[n] = .{ .name = "access-control-allow-headers", .value = value };
                        n += 1;
                    }
                } else if (requested_headers.len != 0) {
                    const value = try util.joinCommaList(req.allocator(), requested_headers);
                    hdrs[n] = .{ .name = "access-control-allow-headers", .value = value };
                    n += 1;
                }

                const methods_value = try util.joinCommaList(req.allocator(), methods);
                hdrs[n] = .{ .name = "access-control-allow-methods", .value = methods_value };
                n += 1;

                if (max_age) |age| {
                    const value = try std.fmt.allocPrint(req.allocator(), "{d}", .{age});
                    hdrs[n] = .{ .name = "access-control-max-age", .value = value };
                    n += 1;
                }

                if (!util.hasHeader(hdrs[0..n], "vary")) {
                    hdrs[n] = .{ .name = "vary", .value = varyHeaderValue(true) };
                    n += 1;
                }

                const headers = try allocHeaders(req.allocator(), hdrs[0..n]);
                return .{ .status = 204, .headers = headers, .body = "" };
            }

            if (!allowed) {
                if (enforce) return Res.text(403, "cors forbidden");
                return next.call(ctx, req);
            }

            var res = try next.call(ctx, req);

            const origin_value = if (allow_any_origin and !allow_credentials) "*" else origin_copy;
            var hdrs: [4]Header = undefined;
            var n: usize = 0;
            hdrs[n] = .{ .name = "access-control-allow-origin", .value = origin_value };
            n += 1;
            if (allow_credentials) {
                hdrs[n] = .{ .name = "access-control-allow-credentials", .value = "true" };
                n += 1;
            }
            if (expose_headers.len != 0) {
                const value = try util.joinCommaList(req.allocator(), expose_headers);
                if (value.len != 0) {
                    hdrs[n] = .{ .name = "access-control-expose-headers", .value = value };
                    n += 1;
                }
            }
            if (!util.hasHeader(hdrs[0..n], "vary") and !(allow_any_origin and !allow_credentials)) {
                hdrs[n] = .{ .name = "vary", .value = varyHeaderValue(false) };
                n += 1;
            }

            res.headers = try appendCorsHeaders(req.allocator(), res.headers, hdrs[0..n]);
            return res;
        }
    };

    return if (store) struct {
        pub const Needs = Common.Needs;
        pub const register_routes = Common.register_routes;
        pub const Routes = Common.Routes;
        pub const Data = Common.Data;
        pub const name = opts.name;
        pub fn call(comptime Next: type, next: Next, ctx: anytype, req: anytype, data: *DataT) !Res {
            return Common.handle(Next, next, ctx, req, data);
        }
    } else struct {
        pub const Needs = Common.Needs;
        pub const register_routes = Common.register_routes;
        pub const Routes = Common.Routes;
        pub const Data = Common.Data;
        pub fn call(comptime Next: type, next: Next, ctx: anytype, req: anytype) !Res {
            return Common.handle(Next, next, ctx, req, null);
        }
    };
}

fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
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
        pub fn call(_: @This(), _: void, _: anytype) !Res {
            return Res.text(200, "ok");
        }
    };

    const gpa = std.testing.allocator;

    {
        const path_buf = "/any".*;
        const query_buf: [0]u8 = .{};
        const line: @import("../request.zig").RequestLine = .{
            .method = "OPTIONS",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
        defer reqv.deinit(gpa);
        var r = std.Io.Reader.fixed("Origin: https://example.com\r\nAccess-Control-Request-Method: POST\r\n\r\n");
        try reqv.parseHeaders(gpa, &r, 1024);

        const res = try Mw.call(Next, Next{}, {}, &reqv);
        try std.testing.expectEqual(@as(u16, 204), res.status);
        try std.testing.expectEqualStrings("https://example.com", headerValue(res.headers, "access-control-allow-origin").?);
    }

    {
        const path_buf = "/any".*;
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
        var r = std.Io.Reader.fixed("Origin: https://example.com\r\n\r\n");
        try reqv.parseHeaders(gpa, &r, 1024);

        const res = try Mw.call(Next, Next{}, {}, &reqv);
        try std.testing.expectEqual(@as(u16, 200), res.status);
        try std.testing.expectEqualStrings("https://example.com", headerValue(res.headers, "access-control-allow-origin").?);
    }
}
