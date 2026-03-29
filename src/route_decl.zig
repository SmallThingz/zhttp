const std = @import("std");

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
    method: []const u8,
    pattern: []const u8,
    /// Endpoint type exposing `pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response(Body)`.
    /// Supported `Body` types are `[]const u8`, `[][]const u8`, `void`, or a custom
    /// struct with `pub fn body(self, comptime rctx, req: rctx.TReadOnly(), cw) !void`.
    endpoint: type,
    headers: type,
    query: type,
    params: type,
    middlewares: []const type,
    operations: []const type,
};

test "EndpointInfo defaults and RouteDecl field layout" {
    const info: EndpointInfo = .{};
    try std.testing.expect(info.headers == null);
    try std.testing.expect(info.query == null);
    try std.testing.expect(info.path == null);
    try std.testing.expectEqual(@as(usize, 0), info.middlewares.len);
    try std.testing.expectEqual(@as(usize, 0), info.operations.len);

    const Endpoint = struct {
        pub const Info: EndpointInfo = .{};
    };
    const rd: RouteDecl = .{
        .method = "GET",
        .pattern = "/x",
        .endpoint = Endpoint,
        .headers = struct {},
        .query = struct {},
        .params = struct {},
        .middlewares = &.{},
        .operations = &.{},
    };
    try std.testing.expectEqualStrings("GET", rd.method);
    try std.testing.expectEqualStrings("/x", rd.pattern);
    try std.testing.expect(rd.endpoint == Endpoint);
}
