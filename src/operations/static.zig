/// Auto-registers middleware-defined static routes.
pub fn Static(comptime Mw: type) type {
    if (!@hasDecl(Mw, "operationRoutes")) {
        @compileError("operations.Static(Mw) requires middleware type " ++ @typeName(Mw) ++ " to expose `pub fn operationRoutes() ...`");
    }

    return struct {
        pub const MaxAddedRoutes: usize = 2;

        pub fn operation(comptime r: anytype) void {
            const extra = Mw.operationRoutes();
            const fields = @typeInfo(@TypeOf(extra)).@"struct".fields;
            inline for (fields) |f| {
                const route_decl = @field(extra, f.name);
                if (!r.hasMethodPath(route_decl.method, route_decl.pattern)) {
                    r.add(route_decl);
                }
            }
        }
    };
}

test "static operation adds GET/HEAD mount routes" {
    const std = @import("std");
    const ops = @import("../operations.zig");
    const router = @import("../router.zig");
    const Res = @import("../response.zig").Res;
    const Mw = @import("../middleware/static.zig").Static(.{ .dir = "public", .mount = "/assets" });

    const out = ops.apply(.{
        router.get("/x", struct {
            fn h() !Res {
                return Res.text(200, "ok");
            }
        }.h, .{}),
    }, .{Mw}, .{Static(Mw)});

    const fields = @typeInfo(@TypeOf(out)).@"struct".fields;
    var found_get: bool = false;
    var found_head: bool = false;
    inline for (fields) |f| {
        const rd = @field(out, f.name);
        if (std.mem.eql(u8, rd.method, "GET") and std.mem.eql(u8, rd.pattern, "/assets/*")) found_get = true;
        if (std.mem.eql(u8, rd.method, "HEAD") and std.mem.eql(u8, rd.pattern, "/assets/*")) found_head = true;
    }
    try std.testing.expect(found_get);
    try std.testing.expect(found_head);
}
