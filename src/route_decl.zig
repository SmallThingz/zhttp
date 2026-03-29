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
