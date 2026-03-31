const std = @import("std");
const zhttp = @import("src/root.zig");
const parse = @import("src/parse.zig");
const request = @import("src/request.zig");
const response = @import("src/response.zig");
const route_decl = @import("src/route_decl.zig");
const router = @import("src/router.zig");
const server = @import("src/server.zig");
const middleware = @import("src/middleware.zig");
const operations = @import("src/operations.zig");
const req_ctx = @import("src/req_ctx.zig");
const upgrade = @import("src/upgrade.zig");
const urldecode = @import("src/urldecode.zig");
const util = @import("src/util.zig");
const operations_context = @import("src/operations/context.zig");
const operations_cors = @import("src/operations/cors.zig");
const operations_static = @import("src/operations/static.zig");
const middleware_compression = @import("src/middleware/compression.zig");
const middleware_cors = @import("src/middleware/cors.zig");
const middleware_etag = @import("src/middleware/etag.zig");
const middleware_expect = @import("src/middleware/expect.zig");
const middleware_logger = @import("src/middleware/logger.zig");
const middleware_origin = @import("src/middleware/origin.zig");
const middleware_request_id = @import("src/middleware/request_id.zig");
const middleware_security_headers = @import("src/middleware/security_headers.zig");
const middleware_static = @import("src/middleware/static.zig");
const middleware_timeout = @import("src/middleware/timeout.zig");
const middleware_test_helpers = @import("src/middleware/test_helpers.zig");
const middleware_util = @import("src/middleware/util.zig");

fn typeSliceContains(comptime types: []const type, comptime needle: type) bool {
    inline for (types) |t| {
        if (t == needle) return true;
    }
    return false;
}

fn skipRecursiveDeclNamespace(comptime T: type) bool {
    const name = @typeName(T);
    return std.mem.eql(u8, name, "std") or
        std.mem.startsWith(u8, name, "std.") or
        std.mem.eql(u8, name, "builtin") or
        std.mem.startsWith(u8, name, "builtin.");
}

fn isNamespaceLikeContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields.len == 0,
        .@"union", .@"enum", .@"opaque" => false,
        else => false,
    };
}

fn refAllDeclsRecursive(comptime T: type) void {
    refAllDeclsRecursiveSeen(T, &.{});
}

fn refAllDeclsRecursiveSeen(comptime T: type, comptime seen: []const type) void {
    if (!@import("builtin").is_test) return;
    if (skipRecursiveDeclNamespace(T)) return;
    if (typeSliceContains(seen, T)) return;

    const next_seen = seen ++ [_]type{T};
    std.testing.refAllDecls(T);

    inline for (comptime std.meta.declarations(T)) |decl| {
        const decl_value = @field(T, decl.name);
        if (@TypeOf(decl_value) != type) continue;
        const Child = decl_value;
        if (comptime !isNamespaceLikeContainer(Child)) continue;
        refAllDeclsRecursiveSeen(Child, next_seen);
    }
}

test "loopback listen preflight" {
    // Use the runner-provided test IO instance directly; constructing and
    // tearing down a fresh Threaded IO here has been unstable in ReleaseFast.
    const io = std.testing.io;

    const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var listener = try std.Io.net.IpAddress.listen(&addr0, io, .{ .reuse_address = true });
    listener.deinit(io);
}

test {
    _ = zhttp;
}

test "refAllDeclsRecursive: every src module compiles all declarations" {
    refAllDeclsRecursive(zhttp);
    refAllDeclsRecursive(parse);
    refAllDeclsRecursive(request);
    refAllDeclsRecursive(response);
    refAllDeclsRecursive(route_decl);
    refAllDeclsRecursive(router);
    refAllDeclsRecursive(server);
    refAllDeclsRecursive(middleware);
    refAllDeclsRecursive(operations);
    refAllDeclsRecursive(req_ctx);
    refAllDeclsRecursive(upgrade);
    refAllDeclsRecursive(urldecode);
    refAllDeclsRecursive(util);
    refAllDeclsRecursive(operations_context);
    refAllDeclsRecursive(operations_cors);
    refAllDeclsRecursive(operations_static);
    refAllDeclsRecursive(middleware_compression);
    refAllDeclsRecursive(middleware_cors);
    refAllDeclsRecursive(middleware_etag);
    refAllDeclsRecursive(middleware_expect);
    refAllDeclsRecursive(middleware_logger);
    refAllDeclsRecursive(middleware_origin);
    refAllDeclsRecursive(middleware_request_id);
    refAllDeclsRecursive(middleware_security_headers);
    refAllDeclsRecursive(middleware_static);
    refAllDeclsRecursive(middleware_timeout);
    refAllDeclsRecursive(middleware_test_helpers);
    refAllDeclsRecursive(middleware_util);
}
