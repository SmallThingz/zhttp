const std = @import("std");

const middleware = @import("middleware.zig");
const router_mod = @import("router.zig");
const util = @import("util.zig");

/// Canonical route declaration type used by operation routers.
pub const RouteDecl = router_mod.RouteDecl;

fn routeTupleType(comptime n: usize) type {
    const Fields = [_]type{RouteDecl} ** n;
    return std.meta.Tuple(&Fields);
}

fn validateRouteTuple(comptime routes: anytype) void {
    const info = @typeInfo(@TypeOf(routes));
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("routes must be a tuple");
    }
}

fn validateOperationType(comptime Op: type) void {
    if (!@hasDecl(Op, "operation")) {
        @compileError("operation type " ++ @typeName(Op) ++ " must expose `pub fn operation(comptime router: anytype) void`");
    }
    const fn_t = @TypeOf(Op.operation);
    const info = @typeInfo(fn_t);
    if (info != .@"fn") {
        @compileError("operation type " ++ @typeName(Op) ++ " operation must be a function");
    }
    const fn_info = info.@"fn";
    if (fn_info.params.len != 1) {
        @compileError("operation type " ++ @typeName(Op) ++ " operation must take exactly one parameter (router)");
    }
    if (fn_info.return_type != void) {
        @compileError("operation type " ++ @typeName(Op) ++ " operation must return void");
    }
}

fn opAddedBudget(comptime Op: type, comptime base_route_count: usize) usize {
    if (@hasDecl(Op, "maxAddedRoutes")) {
        const fn_t = @TypeOf(Op.maxAddedRoutes);
        const info = @typeInfo(fn_t);
        if (info != .@"fn" or info.@"fn".params.len != 1) {
            @compileError("operation type " ++ @typeName(Op) ++ " maxAddedRoutes must be fn(comptime base_route_count: usize) usize");
        }
        const out = @call(.auto, Op.maxAddedRoutes, .{base_route_count});
        if (@TypeOf(out) != usize) {
            @compileError("operation type " ++ @typeName(Op) ++ " maxAddedRoutes must return usize");
        }
        return out;
    }
    if (@hasDecl(Op, "MaxAddedRoutes")) {
        if (@TypeOf(Op.MaxAddedRoutes) != usize) {
            @compileError("operation type " ++ @typeName(Op) ++ " MaxAddedRoutes must be usize");
        }
        return Op.MaxAddedRoutes;
    }
    return 0;
}

fn totalAddedBudget(comptime ops: []const type, comptime base_route_count: usize) usize {
    comptime var total: usize = 0;
    inline for (ops) |Op| {
        total += opAddedBudget(Op, base_route_count);
    }
    return total;
}

/// Mutable compile-time route table helper used by operations.
///
/// `capacity` must cover base routes plus all routes an operations tuple may add.
pub fn Router(comptime capacity: usize, comptime global_middlewares: []const type) type {
    return struct {
        const Self = @This();

        pub const PathGroup = struct {
            path: []const u8,
            indices: []const usize,
        };

        _routes: [capacity]RouteDecl = undefined,
        _len: usize = 0,
        _index_buf: [capacity]usize = undefined,
        _path_buf: [capacity][]const u8 = undefined,
        _group_buf: [capacity]usize = undefined,

        pub fn init(comptime routes: anytype) Self {
            validateRouteTuple(routes);
            const fields = @typeInfo(@TypeOf(routes)).@"struct".fields;
            if (fields.len > capacity) {
                @compileError("operations router capacity is smaller than base route count");
            }

            var out: Self = undefined;
            out._len = fields.len;
            inline for (fields, 0..) |f, i| {
                out._routes[i] = @field(routes, f.name);
            }
            return out;
        }

        pub fn count(comptime self: *const Self) usize {
            return self._len;
        }

        pub fn all(comptime self: *const Self) []const RouteDecl {
            return self._routes[0..self._len];
        }

        pub fn route(comptime self: *Self, index: usize) *RouteDecl {
            if (index >= self._len) @compileError("route index out of bounds");
            return &self._routes[index];
        }

        pub fn routeConst(comptime self: *const Self, index: usize) *const RouteDecl {
            if (index >= self._len) @compileError("route index out of bounds");
            return &self._routes[index];
        }

        fn ensureCanAdd(comptime self: *const Self) void {
            if (self._len >= capacity) {
                @compileError("operations router capacity exhausted; increase operation MaxAddedRoutes/maxAddedRoutes budget");
            }
        }

        pub fn add(comptime self: *Self, route_decl: RouteDecl) void {
            self.ensureCanAdd();
            self._routes[self._len] = route_decl;
            self._len += 1;
        }

        pub fn addMany(comptime self: *Self, comptime routes: anytype) void {
            validateRouteTuple(routes);
            const fields = @typeInfo(@TypeOf(routes)).@"struct".fields;
            inline for (fields) |f| {
                self.add(@field(routes, f.name));
            }
        }

        pub fn insert(comptime self: *Self, index: usize, route_decl: RouteDecl) void {
            if (index > self._len) @compileError("route index out of bounds");
            self.ensureCanAdd();
            var i: usize = self._len;
            while (i > index) : (i -= 1) {
                self._routes[i] = self._routes[i - 1];
            }
            self._routes[index] = route_decl;
            self._len += 1;
        }

        pub fn replace(comptime self: *Self, index: usize, route_decl: RouteDecl) RouteDecl {
            if (index >= self._len) @compileError("route index out of bounds");
            const prev = self._routes[index];
            self._routes[index] = route_decl;
            return prev;
        }

        pub fn remove(comptime self: *Self, index: usize) RouteDecl {
            if (index >= self._len) @compileError("route index out of bounds");
            const prev = self._routes[index];
            var i = index;
            while (i + 1 < self._len) : (i += 1) {
                self._routes[i] = self._routes[i + 1];
            }
            self._len -= 1;
            return prev;
        }

        pub fn swapRemove(comptime self: *Self, index: usize) RouteDecl {
            if (index >= self._len) @compileError("route index out of bounds");
            const prev = self._routes[index];
            self._len -= 1;
            if (index < self._len) {
                self._routes[index] = self._routes[self._len];
            }
            return prev;
        }

        pub fn clear(comptime self: *Self) void {
            self._len = 0;
        }

        fn middlewareHasDecl(comptime Mw: type, comptime decl_name: []const u8) bool {
            return @hasDecl(Mw, decl_name);
        }

        fn middlewareDeclEquals(comptime Mw: type, comptime decl_name: []const u8, comptime decl_value: anytype) bool {
            if (!@hasDecl(Mw, decl_name)) return false;
            const got = @field(Mw, decl_name);
            return @TypeOf(got) == @TypeOf(decl_value) and got == decl_value;
        }

        fn routeHasMiddleware(comptime route_decl: RouteDecl, comptime Mw: type) bool {
            inline for (global_middlewares) |GlobalMw| {
                if (GlobalMw == Mw) return true;
            }
            inline for (route_decl.middlewares) |RouteMw| {
                if (RouteMw == Mw) return true;
            }
            return false;
        }

        fn routeHasMiddlewareDecl(comptime route_decl: RouteDecl, comptime decl_name: []const u8) bool {
            inline for (global_middlewares) |GlobalMw| {
                if (middlewareHasDecl(GlobalMw, decl_name)) return true;
            }
            inline for (route_decl.middlewares) |RouteMw| {
                if (middlewareHasDecl(RouteMw, decl_name)) return true;
            }
            return false;
        }

        pub fn hasMiddleware(comptime self: *const Self, index: usize, comptime Mw: type) bool {
            return routeHasMiddleware(self.routeConst(index).*, Mw);
        }

        pub fn hasSignature(comptime self: *const Self, index: usize, comptime Signature: type) bool {
            return self.firstMiddlewareWithDeclValue(index, "Signature", Signature) != null;
        }

        pub fn hasMiddlewareDecl(comptime self: *const Self, index: usize, comptime decl_name: []const u8) bool {
            return routeHasMiddlewareDecl(self.routeConst(index).*, decl_name);
        }

        pub fn firstMiddlewareWithSignature(comptime self: *const Self, index: usize, comptime Signature: type) ?type {
            return self.firstMiddlewareWithDeclValue(index, "Signature", Signature);
        }

        pub fn firstMiddlewareWithDecl(comptime self: *const Self, index: usize, comptime decl_name: []const u8) ?type {
            const route_decl = self.routeConst(index).*;
            inline for (global_middlewares) |GlobalMw| {
                if (middlewareHasDecl(GlobalMw, decl_name)) return GlobalMw;
            }
            inline for (route_decl.middlewares) |RouteMw| {
                if (middlewareHasDecl(RouteMw, decl_name)) return RouteMw;
            }
            return null;
        }

        pub fn firstMiddlewareWithDeclValue(comptime self: *const Self, index: usize, comptime decl_name: []const u8, comptime decl_value: anytype) ?type {
            const route_decl = self.routeConst(index).*;
            inline for (global_middlewares) |GlobalMw| {
                if (middlewareDeclEquals(GlobalMw, decl_name, decl_value)) return GlobalMw;
            }
            inline for (route_decl.middlewares) |RouteMw| {
                if (middlewareDeclEquals(RouteMw, decl_name, decl_value)) return RouteMw;
            }
            return null;
        }

        pub fn hasMethodPath(comptime self: *const Self, method: []const u8, pattern: []const u8) bool {
            inline for (self.all()) |route_decl| {
                if (std.mem.eql(u8, route_decl.method, method) and std.mem.eql(u8, route_decl.pattern, pattern)) {
                    return true;
                }
            }
            return false;
        }

        pub fn filterByMiddleware(comptime self: *Self, comptime Mw: type) []const usize {
            comptime var n: usize = 0;
            inline for (self.all(), 0..) |route_decl, i| {
                if (routeHasMiddleware(route_decl, Mw)) {
                    self._index_buf[n] = i;
                    n += 1;
                }
            }
            return self._index_buf[0..n];
        }

        pub fn filterBySignature(comptime self: *Self, comptime Signature: type) []const usize {
            comptime var n: usize = 0;
            inline for (self.all(), 0..) |_, i| {
                if (self.firstMiddlewareWithDeclValue(i, "Signature", Signature) != null) {
                    self._index_buf[n] = i;
                    n += 1;
                }
            }
            return self._index_buf[0..n];
        }

        pub fn filterByMiddlewareDecl(comptime self: *Self, comptime decl_name: []const u8) []const usize {
            comptime var n: usize = 0;
            inline for (self.all(), 0..) |route_decl, i| {
                if (routeHasMiddlewareDecl(route_decl, decl_name)) {
                    self._index_buf[n] = i;
                    n += 1;
                }
            }
            return self._index_buf[0..n];
        }

        pub fn forEachPathGroup(comptime self: *Self, indices: []const usize, comptime callback: anytype) void {
            comptime var path_count: usize = 0;

            for (indices) |idx| {
                const path = self.routeConst(idx).pattern;
                var seen = false;
                var i: usize = 0;
                while (i < path_count) : (i += 1) {
                    if (std.mem.eql(u8, self._path_buf[i], path)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    self._path_buf[path_count] = path;
                    path_count += 1;
                }
            }

            var pidx: usize = 0;
            while (pidx < path_count) : (pidx += 1) {
                const path = self._path_buf[pidx];
                var g_n: usize = 0;
                for (indices) |idx| {
                    if (std.mem.eql(u8, self.routeConst(idx).pattern, path)) {
                        self._group_buf[g_n] = idx;
                        g_n += 1;
                    }
                }
                @call(.auto, callback, .{ self, PathGroup{ .path = path, .indices = self._group_buf[0..g_n] } });
            }
        }

        pub fn forEachPathGroupByMiddleware(comptime self: *Self, comptime Mw: type, comptime callback: anytype) void {
            const indices = self.filterByMiddleware(Mw);
            self.forEachPathGroup(indices, callback);
        }

        pub fn forEachPathGroupBySignature(comptime self: *Self, comptime Signature: type, comptime callback: anytype) void {
            const indices = self.filterBySignature(Signature);
            self.forEachPathGroup(indices, callback);
        }

        pub fn toTuple(comptime self: *const Self, comptime out_len: usize) routeTupleType(out_len) {
            if (self._len != out_len) {
                @compileError("operation route count changed between sizing and build pass");
            }
            var out: routeTupleType(out_len) = undefined;
            inline for (0..out_len) |i| {
                @field(out, std.fmt.comptimePrint("{d}", .{i})) = self._routes[i];
            }
            return out;
        }
    };
}

fn validateOperationsTuple(comptime operations_tuple: anytype) []const type {
    return middleware.typeList(operations_tuple);
}

fn finalLen(
    comptime routes_tuple: anytype,
    comptime global_middlewares_tuple: anytype,
    comptime operations_tuple: anytype,
) usize {
    validateRouteTuple(routes_tuple);
    const ops = validateOperationsTuple(operations_tuple);
    const global_mws = middleware.typeList(global_middlewares_tuple);
    const base_count = util.tupleLen(routes_tuple);
    const capacity = base_count + totalAddedBudget(ops, base_count);
    const RouterT = Router(capacity, global_mws);

    var router = RouterT.init(routes_tuple);
    inline for (ops) |Op| {
        validateOperationType(Op);
        @call(.auto, Op.operation, .{&router});
    }
    return router.count();
}

fn applyWithLen(
    comptime out_len: usize,
    comptime routes_tuple: anytype,
    comptime global_middlewares_tuple: anytype,
    comptime operations_tuple: anytype,
) routeTupleType(out_len) {
    const ops = validateOperationsTuple(operations_tuple);
    const global_mws = middleware.typeList(global_middlewares_tuple);
    const base_count = util.tupleLen(routes_tuple);
    const capacity = base_count + totalAddedBudget(ops, base_count);
    const RouterT = Router(capacity, global_mws);

    var router = RouterT.init(routes_tuple);
    inline for (ops) |Op| {
        validateOperationType(Op);
        @call(.auto, Op.operation, .{&router});
    }
    return router.toTuple(out_len);
}

/// Runs registered route operations and returns the final route tuple.
pub fn apply(
    comptime routes_tuple: anytype,
    comptime global_middlewares_tuple: anytype,
    comptime operations_tuple: anytype,
) routeTupleType(finalLen(routes_tuple, global_middlewares_tuple, operations_tuple)) {
    const out_len = comptime finalLen(routes_tuple, global_middlewares_tuple, operations_tuple);
    return comptime applyWithLen(out_len, routes_tuple, global_middlewares_tuple, operations_tuple);
}

/// Built-in operation that synthesizes CORS preflight `OPTIONS` routes.
pub const Cors = @import("operations/cors.zig").Cors;
/// Built-in operation that synthesizes static middleware mount routes.
pub const Static = @import("operations/static.zig").Static;

test "operations: add and remove routes" {
    const Ops = struct {
        pub const MaxAddedRoutes: usize = 1;
        pub fn operation(comptime r: anytype) void {
            r.add(router_mod.get("/b", struct {
                pub fn call(comptime _: @import("req_ctx.zig").ReqCtx, req: anytype) !@import("response.zig").Res {
                    _ = req;
                    return @import("response.zig").Res.text(200, "b");
                }
            }, .{}));
            _ = r.remove(0);
        }
    };

    const out = apply(.{
        router_mod.get("/a", struct {
            pub fn call(comptime _: @import("req_ctx.zig").ReqCtx, req: anytype) !@import("response.zig").Res {
                _ = req;
                return @import("response.zig").Res.text(200, "a");
            }
        }, .{}),
    }, .{}, .{Ops});

    const fields = @typeInfo(@TypeOf(out)).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("/b", @field(out, fields[0].name).pattern);
}

test "operations: order is tuple order and later ops see latest table" {
    const Res = @import("response.zig").Res;
    const OpA = struct {
        pub const MaxAddedRoutes: usize = 1;
        pub fn operation(comptime r: anytype) void {
            r.add(router_mod.get("/later", struct {
                pub fn call(comptime _: @import("req_ctx.zig").ReqCtx, req: anytype) !Res {
                    _ = req;
                    return Res.text(200, "later");
                }
            }, .{}));
        }
    };
    const OpB = struct {
        pub fn operation(comptime r: anytype) void {
            if (r.hasMethodPath("GET", "/later")) {
                _ = r.replace(0, router_mod.get("/first-replaced", struct {
                    pub fn call(comptime _: @import("req_ctx.zig").ReqCtx, req: anytype) !Res {
                        _ = req;
                        return Res.text(200, "first");
                    }
                }, .{}));
            }
        }
    };

    const out = apply(.{
        router_mod.get("/first", struct {
            pub fn call(comptime _: @import("req_ctx.zig").ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "first");
            }
        }, .{}),
    }, .{}, .{ OpA, OpB });

    const fields = @typeInfo(@TypeOf(out)).@"struct".fields;
    try std.testing.expectEqualStrings("/first-replaced", @field(out, fields[0].name).pattern);
}
