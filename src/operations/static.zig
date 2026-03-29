const std = @import("std");
const OperationCtx = @import("context.zig").OperationCtx;

/// Built-in operation that auto-registers static middleware routes.
///
/// For each route carrying a middleware exposing `operationRoutes()`, this
/// operation inspects the selected middleware type and imports its routes
/// (typically `GET` and `HEAD` mount routes) if missing.
pub const Static = struct {
    /// Upper bound used by the operations planner.
    ///
    /// A static middleware contributes at most two synthetic routes (`GET` + `HEAD`).
    pub fn maxAddedRoutes(comptime base_route_count: usize) usize {
        return base_route_count * 2;
    }

    fn addRoutesForMiddleware(comptime r: anytype, comptime Mw: type) void {
        if (!@hasDecl(Mw, "operationRoutes")) {
            @compileError("operations.Static: middleware type " ++ @typeName(Mw) ++ " must expose `pub fn operationRoutes() ...`");
        }
        const extra = Mw.operationRoutes();
        const fields = @typeInfo(@TypeOf(extra)).@"struct".fields;
        inline for (fields) |f| {
            const route_decl = @field(extra, f.name);
            if (!r.hasMethodPath(route_decl.method, route_decl.pattern)) {
                r.add(route_decl);
            }
        }
    }

    /// Applies the operation to the mutable compile-time route table.
    pub fn operation(comptime opctx: OperationCtx, r: opctx.T()) void {
        const op_indices = opctx.filter(r);
        for (op_indices) |idx| {
            if (!r.hasMiddlewareDecl(idx, "operationRoutes")) continue;
            const selected_mw = r.firstMiddlewareWithDecl(idx, "operationRoutes") orelse
                @compileError("operations.Static: expected at least one middleware exposing `operationRoutes()`");
            addRoutesForMiddleware(r, selected_mw);
        }
    }
};

test "static operation maxAddedRoutes reserves two per route" {
    try std.testing.expectEqual(@as(usize, 0), Static.maxAddedRoutes(0));
    try std.testing.expectEqual(@as(usize, 8), Static.maxAddedRoutes(4));
}

test "static operation adds GET/HEAD mount routes" {
    const ops = @import("../operations.zig");
    const router = @import("../router.zig");
    const Res = @import("../response.zig").Res;
    const Mw = @import("../middleware/static.zig").Static(.{ .dir = "public", .mount = "/assets" });

    const out = ops.apply(.{
        router.get("/x", struct {
            pub const Info: router.EndpointInfo = .{
                .operations = &.{Static},
            };
            pub fn call(comptime rctx: @import("../req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }),
    }, .{Mw}, .{Static});

    const fields = @typeInfo(@TypeOf(out)).@"struct".fields;
    var found_get: bool = false;
    var found_head: bool = false;
    inline for (fields) |f| {
        const rd = @field(out, f.name);
        if (std.mem.eql(u8, rd.method, "GET") and std.mem.eql(u8, rd.pattern, "/assets/{*path}")) found_get = true;
        if (std.mem.eql(u8, rd.method, "HEAD") and std.mem.eql(u8, rd.pattern, "/assets/{*path}")) found_head = true;
    }
    try std.testing.expect(found_get);
    try std.testing.expect(found_head);
}
