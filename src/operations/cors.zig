const std = @import("std");
const router = @import("../router.zig");
const response = @import("../response.zig");

/// Auto-registers CORS preflight `OPTIONS` routes for each path that carries `Mw.Signature`.
pub fn Cors(comptime Mw: type) type {
    if (!@hasDecl(Mw, "Signature")) {
        @compileError("operations.Cors(Mw) requires middleware type " ++ @typeName(Mw) ++ " to expose `pub const Signature = ...`");
    }
    const Signature = Mw.Signature;

    return struct {
        pub fn maxAddedRoutes(comptime base_route_count: usize) usize {
            return base_route_count;
        }

        fn defaultOptionsHandler(_: anytype) !response.Res {
            return response.Res.text(404, "not found");
        }

        fn onGroup(comptime r: anytype, group: anytype) void {
            if (group.indices.len == 0) return;
            if (r.hasMethodPath("OPTIONS", group.path)) return;

            const selected_mw = r.firstMiddlewareWithSignature(group.indices[0], Signature) orelse
                @compileError("operations.Cors: expected at least one middleware matching signature " ++ @typeName(Signature));

            r.add(router.options(group.path, defaultOptionsHandler, .{
                .middlewares = .{selected_mw},
            }));
        }

        pub fn operation(comptime r: anytype) void {
            const indices = r.filterBySignature(Signature);
            r.forEachPathGroup(indices, onGroup);
        }
    };
}

test "cors operation adds one OPTIONS route per matched path" {
    const ops = @import("../operations.zig");
    const Res = @import("../response.zig").Res;
    const Mw = @import("../middleware/cors.zig").Cors(.{ .origins = &.{"https://example.com"} });

    const out = ops.apply(.{
        router.get("/a", struct {
            fn h() !Res {
                return Res.text(200, "ok");
            }
        }.h, .{ .middlewares = .{Mw} }),
        router.post("/a", struct {
            fn h() !Res {
                return Res.text(200, "ok");
            }
        }.h, .{ .middlewares = .{Mw} }),
        router.get("/b", struct {
            fn h() !Res {
                return Res.text(200, "ok");
            }
        }.h, .{}),
    }, .{}, .{Cors(Mw)});

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
