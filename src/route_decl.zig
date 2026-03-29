/// Compile-time endpoint metadata.
pub const EndpointInfo = struct {
    /// Optional request header capture schema.
    headers: ?type = null,
    /// Optional query capture schema.
    query: ?type = null,
    /// Optional path-param capture schema.
    path: ?type = null,
    /// Per-endpoint middleware types.
    middlewares: []const type = &.{},
    /// Per-endpoint operation types.
    operations: []const type = &.{},
};

/// Fully resolved route declaration shape used across router/server/request.
pub const RouteDecl = struct {
    /// Stores `method`.
    method: []const u8,
    /// Stores `pattern`.
    pattern: []const u8,
    /// Stores endpoint type exposing `pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response(Body)`.
    ///
    /// Supported `Body` types are `[]const u8`, `[][]const u8`, `void`, or a
    /// custom struct with `pub fn body(self, comptime rctx, req: rctx.TReadOnly(), cw) !void`.
    endpoint: type,
    /// Stores `headers`.
    headers: type,
    /// Stores `query`.
    query: type,
    /// Stores `params`.
    params: type,
    /// Stores `middlewares`.
    middlewares: []const type,
    /// Stores `operations`.
    operations: []const type,
};

test "EndpointInfo: defaults are empty" {
    const info: EndpointInfo = .{};
    try @import("std").testing.expect(info.headers == null);
    try @import("std").testing.expect(info.query == null);
    try @import("std").testing.expect(info.path == null);
    try @import("std").testing.expectEqual(@as(usize, 0), info.middlewares.len);
    try @import("std").testing.expectEqual(@as(usize, 0), info.operations.len);
}

test "RouteDecl: stores resolved route metadata" {
    const DummyEndpoint = struct {};
    const route: RouteDecl = .{
        .method = "GET",
        .pattern = "/users/{id}",
        .endpoint = DummyEndpoint,
        .headers = struct { host: []const u8 },
        .query = struct { page: u8 },
        .params = struct { id: u32 },
        .middlewares = &.{struct {}},
        .operations = &.{struct {}},
    };

    try @import("std").testing.expectEqualStrings("GET", route.method);
    try @import("std").testing.expectEqualStrings("/users/{id}", route.pattern);
    try @import("std").testing.expect(route.endpoint == DummyEndpoint);
    try @import("std").testing.expectEqual(@as(usize, 1), route.middlewares.len);
    try @import("std").testing.expectEqual(@as(usize, 1), route.operations.len);
}

test "RouteDecl: preserves capture and endpoint types exactly" {
    const std = @import("std");

    const Headers = struct { host: []const u8 };
    const Query = struct { page: u8 };
    const Params = struct { id: u32 };
    const Middleware = struct {};
    const Operation = struct {};
    const Endpoint = struct {};

    const route: RouteDecl = .{
        .method = "POST",
        .pattern = "/items/{id}",
        .endpoint = Endpoint,
        .headers = Headers,
        .query = Query,
        .params = Params,
        .middlewares = &.{Middleware},
        .operations = &.{Operation},
    };

    try std.testing.expect(route.headers == Headers);
    try std.testing.expect(route.query == Query);
    try std.testing.expect(route.params == Params);
    try std.testing.expect(route.middlewares[0] == Middleware);
    try std.testing.expect(route.operations[0] == Operation);
}
