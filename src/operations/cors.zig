const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");
const CorsSignature = @import("../middleware/cors.zig").CorsSignature;

/// Built-in operation that auto-registers CORS preflight `OPTIONS` routes.
///
/// Any route path that is protected by a middleware exposing `CorsSignature`
/// gets one synthetic `OPTIONS` route (if missing) with that middleware attached.
pub const Cors = struct {
    /// Upper bound used by the operations planner.
    ///
    /// In the worst case every base route can contribute one synthetic OPTIONS route.
    pub fn maxAddedRoutes(comptime base_route_count: usize) usize {
        return base_route_count;
    }

    const DefaultOptionsEndpoint = struct {
        pub fn call(comptime _: @import("../req_ctx.zig").ReqCtx, req: anytype) !response.Res {
            _ = req;
            return response.Res.text(404, "not found");
        }
    };

    fn onGroup(comptime r: anytype, group: anytype) void {
        if (group.indices.len == 0) return;
        if (r.hasMethodPath("OPTIONS", group.path)) return;

        const selected_mw = r.firstMiddlewareWithSignature(group.indices[0], CorsSignature) orelse
            @compileError("operations.Cors: expected at least one middleware matching signature " ++ @typeName(CorsSignature));

        r.add(router.options(group.path, DefaultOptionsEndpoint, .{
            .middlewares = .{selected_mw},
        }));
    }

    /// Applies the operation to the mutable compile-time route table.
    pub fn operation(comptime r: anytype) void {
        const indices = r.filterBySignature(CorsSignature);
        r.forEachPathGroup(indices, onGroup);
    }
};

test "cors operation adds one OPTIONS route per matched path" {
    const ops = @import("../operations.zig");
    const Res = @import("../response.zig").Res;
    const Mw = @import("../middleware/cors.zig").Cors(.{ .origins = &.{"https://example.com"} });

    const out = ops.apply(.{
        router.get("/a", struct {
            pub fn call(comptime _: @import("../req_ctx.zig").ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }, .{ .middlewares = .{Mw} }),
        router.post("/a", struct {
            pub fn call(comptime _: @import("../req_ctx.zig").ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }, .{ .middlewares = .{Mw} }),
        router.get("/b", struct {
            pub fn call(comptime _: @import("../req_ctx.zig").ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }, .{}),
    }, .{}, .{Cors});

    const fields = @typeInfo(@TypeOf(out)).@"struct".fields;
    var options_a: usize = 0;
    var options_b: usize = 0;
    inline for (fields) |f| {
        const rd = @field(out, f.name);
        if (std.mem.eql(u8, rd.method, "OPTIONS") and std.mem.eql(u8, rd.pattern, "/a")) options_a += 1;
        if (std.mem.eql(u8, rd.method, "OPTIONS") and std.mem.eql(u8, rd.pattern, "/b")) options_b += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), options_a);
    try std.testing.expectEqual(@as(usize, 0), options_b);
}
