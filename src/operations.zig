const std = @import("std");

const middleware = @import("middleware.zig");
const router_mod = @import("router.zig");
const util = @import("util.zig");
const OperationCtxType = @import("operations/context.zig").OperationCtx;

comptime {
    @setEvalBranchQuota(200_000);
}

/// Canonical route declaration type used by operation routers.
pub const RouteDecl = router_mod.RouteDecl;

/// Compile-time operation context passed into `operation(...)`.
pub const OperationCtx = OperationCtxType;

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
        @compileError("operation type " ++ @typeName(Op) ++ " must expose `pub fn operation(comptime opctx: zhttp.operations.OperationCtx, router: opctx.T()) void`");
    }
    const fn_t = @TypeOf(Op.operation);
    const info = @typeInfo(fn_t);
    if (info != .@"fn") {
        @compileError("operation type " ++ @typeName(Op) ++ " operation must be a function");
    }
    const fn_info = info.@"fn";
    if (fn_info.params.len != 2) {
        @compileError("operation type " ++ @typeName(Op) ++ " operation must take exactly two parameters (opctx, router)");
    }
    const p0 = fn_info.params[0].type orelse
        @compileError("operation type " ++ @typeName(Op) ++ " operation first parameter must have an explicit type");
    if (p0 != OperationCtx) {
        @compileError("operation type " ++ @typeName(Op) ++ " operation first parameter must be zhttp.operations.OperationCtx");
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
        @compileError("operation type " ++ @typeName(Op) ++ " uses legacy `MaxAddedRoutes`; rename it to `maxAddedRoutes(comptime base_route_count: usize) usize`");
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

        fn routeHasOperation(comptime route_decl: RouteDecl, comptime Op: type) bool {
            inline for (route_decl.operations) |RouteOp| {
                if (RouteOp == Op) return true;
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

        pub fn hasOperation(comptime self: *const Self, index: usize, comptime Op: type) bool {
            return routeHasOperation(self.routeConst(index).*, Op);
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

        pub fn filterByOperation(comptime self: *Self, comptime Op: type) []const usize {
            comptime var n: usize = 0;
            inline for (self.all(), 0..) |route_decl, i| {
                if (routeHasOperation(route_decl, Op)) {
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
        const opctx: OperationCtx = .{
            .operation = Op,
            .router_type = RouterT,
        };
        @call(.auto, Op.operation, .{ opctx, &router });
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
        const opctx: OperationCtx = .{
            .operation = Op,
            .router_type = RouterT,
        };
        @call(.auto, Op.operation, .{ opctx, &router });
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
        pub fn maxAddedRoutes(comptime _: usize) usize {
            return 1;
        }
        pub fn operation(comptime opctx: OperationCtx, r: opctx.T()) void {
            r.add(router_mod.get("/b", struct {
                pub const Info: router_mod.EndpointInfo = .{};
                pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !@import("response.zig").Res {
                    _ = req;
                    return @import("response.zig").Res.text(200, "b");
                }
            }));
            _ = r.remove(0);
        }
    };

    const out = apply(.{
        router_mod.get("/a", struct {
            pub const Info: router_mod.EndpointInfo = .{
                .operations = &.{Ops},
            };
            pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !@import("response.zig").Res {
                _ = req;
                return @import("response.zig").Res.text(200, "a");
            }
        }),
    }, .{}, .{Ops});

    const fields = @typeInfo(@TypeOf(out)).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("/b", @field(out, fields[0].name).pattern);
}

test "operations: order is tuple order and later ops see latest table" {
    const Res = @import("response.zig").Res;
    const OpA = struct {
        pub fn maxAddedRoutes(comptime _: usize) usize {
            return 1;
        }
        pub fn operation(comptime opctx: OperationCtx, r: opctx.T()) void {
            r.add(router_mod.get("/later", struct {
                pub const Info: router_mod.EndpointInfo = .{};
                pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
                    _ = req;
                    return Res.text(200, "later");
                }
            }));
        }
    };
    const OpB = struct {
        pub fn operation(comptime opctx: OperationCtx, r: opctx.T()) void {
            if (r.hasMethodPath("GET", "/later")) {
                _ = r.replace(0, router_mod.get("/first-replaced", struct {
                    pub const Info: router_mod.EndpointInfo = .{};
                    pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
                        _ = req;
                        return Res.text(200, "first");
                    }
                }));
            }
        }
    };

    const out = apply(.{
        router_mod.get("/first", struct {
            pub const Info: router_mod.EndpointInfo = .{
                .operations = &.{ OpA, OpB },
            };
            pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "first");
            }
        }),
    }, .{}, .{ OpA, OpB });

    const fields = @typeInfo(@TypeOf(out)).@"struct".fields;
    try std.testing.expectEqualStrings("/first-replaced", @field(out, fields[0].name).pattern);
}

test "operations: operation receives only routes tagged in endpoint Info.operations" {
    const Res = @import("response.zig").Res;
    const TaggedOp = struct {
        pub fn operation(comptime opctx: OperationCtx, r: opctx.T()) void {
            const op_indices = opctx.filter(r);
            if (op_indices.len != 1) {
                @compileError("expected exactly one tagged route");
            }
            const idx = op_indices[0];
            _ = r.replace(idx, router_mod.get("/tagged-replaced", struct {
                pub const Info: router_mod.EndpointInfo = .{};
                pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
                    _ = req;
                    return Res.text(200, "tagged");
                }
            }));
        }
    };

    const out = apply(.{
        router_mod.get("/untagged", struct {
            pub const Info: router_mod.EndpointInfo = .{};
            pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "u");
            }
        }),
        router_mod.get("/tagged", struct {
            pub const Info: router_mod.EndpointInfo = .{
                .operations = &.{TaggedOp},
            };
            pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "t");
            }
        }),
    }, .{}, .{TaggedOp});

    const f = @typeInfo(@TypeOf(out)).@"struct".fields;
    try std.testing.expectEqualStrings("/untagged", @field(out, f[0].name).pattern);
    try std.testing.expectEqualStrings("/tagged-replaced", @field(out, f[1].name).pattern);
}

test "operations router helpers: filters, grouping, mutation, and tuple export" {
    const Res = @import("response.zig").Res;
    const Sig = struct {};
    const Op = struct {};
    const GlobalMw = struct {
        pub const Signature = Sig;
        pub const Marker = true;
        pub const Info: middleware.MiddlewareInfo = .{ .name = "global" };

        pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
            _ = req;
            unreachable;
        }
    };
    const RouteMw = struct {
        pub const Info: middleware.MiddlewareInfo = .{ .name = "route" };

        pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
            _ = req;
            unreachable;
        }
    };
    const E1 = struct {
        pub const Info: router_mod.EndpointInfo = .{
            .middlewares = &.{RouteMw},
            .operations = &.{Op},
        };

        pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
            _ = req;
            return Res.text(200, "a");
        }
    };
    const E2 = struct {
        pub const Info: router_mod.EndpointInfo = .{};

        pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
            _ = req;
            return Res.text(200, "b");
        }
    };
    const E3 = struct {
        pub const Info: router_mod.EndpointInfo = .{
            .operations = &.{Op},
        };

        pub fn call(comptime rctx: @import("req_ctx.zig").ReqCtx, req: rctx.T()) !Res {
            _ = req;
            return Res.text(200, "c");
        }
    };

    const RouterT = Router(6, &.{GlobalMw});
    const Result = comptime blk: {
        var router = RouterT.init(.{
            router_mod.get("/a", E1),
            router_mod.post("/a", E2),
            router_mod.get("/b", E3),
        });

        if (router.count() != 3) @compileError("bad initial count");
        if (router.all().len != 3) @compileError("bad initial slice len");
        if (!std.mem.eql(u8, router.routeConst(0).pattern, "/a")) @compileError("bad routeConst");
        if (!std.mem.eql(u8, router.route(1).method, "POST")) @compileError("bad route");
        if (!router.hasMiddleware(0, GlobalMw)) @compileError("missing global middleware");
        if (!router.hasMiddleware(0, RouteMw)) @compileError("missing route middleware");
        if (!router.hasSignature(0, Sig)) @compileError("missing signature");
        if (!router.hasMiddlewareDecl(0, "Marker")) @compileError("missing decl");
        if (!router.hasOperation(0, Op)) @compileError("missing op");
        if (!router.hasMethodPath("GET", "/b")) @compileError("missing method/path");
        if (router.firstMiddlewareWithDecl(0, "Marker") != GlobalMw) @compileError("bad first decl");
        if (router.firstMiddlewareWithDeclValue(0, "Signature", Sig) != GlobalMw) @compileError("bad first decl value");
        if (router.firstMiddlewareWithSignature(0, Sig) != GlobalMw) @compileError("bad first signature");
        if (!std.mem.eql(usize, router.filterByMiddleware(RouteMw), &.{0})) @compileError("bad filterByMiddleware");
        if (!std.mem.eql(usize, router.filterByOperation(Op), &.{ 0, 2 })) @compileError("bad filterByOperation");
        if (!std.mem.eql(usize, router.filterBySignature(Sig), &.{ 0, 1, 2 })) @compileError("bad filterBySignature");
        if (!std.mem.eql(usize, router.filterByMiddlewareDecl("Marker"), &.{ 0, 1, 2 })) @compileError("bad filterByMiddlewareDecl");

        const GroupAll = struct {
            fn collect(_: *RouterT, group: RouterT.PathGroup) void {
                if (std.mem.eql(u8, group.path, "/a")) {
                    if (!std.mem.eql(usize, group.indices, &.{ 0, 1 })) @compileError("bad /a group");
                    return;
                }
                if (std.mem.eql(u8, group.path, "/b")) {
                    if (!std.mem.eql(usize, group.indices, &.{2})) @compileError("bad /b group");
                    return;
                }
                @compileError("unexpected group");
            }
        };
        const GroupOne = struct {
            fn collect(_: *RouterT, group: RouterT.PathGroup) void {
                if (!std.mem.eql(u8, group.path, "/a")) @compileError("unexpected filtered group path");
                if (!std.mem.eql(usize, group.indices, &.{0})) @compileError("unexpected filtered group indices");
            }
        };
        const GroupSig = struct {
            fn collect(_: *RouterT, group: RouterT.PathGroup) void {
                if (std.mem.eql(u8, group.path, "/a")) {
                    if (!std.mem.eql(usize, group.indices, &.{ 0, 1 })) @compileError("bad signature /a group");
                    return;
                }
                if (std.mem.eql(u8, group.path, "/b")) {
                    if (!std.mem.eql(usize, group.indices, &.{2})) @compileError("bad signature /b group");
                    return;
                }
                @compileError("unexpected signature group");
            }
        };
        router.forEachPathGroup(&.{ 0, 1, 2 }, GroupAll.collect);
        router.forEachPathGroupByMiddleware(RouteMw, GroupOne.collect);
        router.forEachPathGroupBySignature(Sig, GroupSig.collect);

        router.insert(1, router_mod.head("/a", E2));
        if (!std.mem.eql(u8, router.routeConst(1).method, "HEAD")) @compileError("bad insert");
        const replaced_prev = router.replace(1, router_mod.options("/a", E2));
        if (!std.mem.eql(u8, replaced_prev.method, "HEAD")) @compileError("bad replace");
        const removed = router.remove(0);
        if (!std.mem.eql(u8, removed.pattern, "/a")) @compileError("bad remove");
        const swapped = router.swapRemove(2);
        if (!std.mem.eql(u8, swapped.pattern, "/b")) @compileError("bad swapRemove");
        if (router.count() != 2) @compileError("bad final count");

        const tuple = router.toTuple(2);
        const fields = @typeInfo(@TypeOf(tuple)).@"struct".fields;
        if (!std.mem.eql(u8, router.routeConst(0).pattern, @field(tuple, fields[0].name).pattern)) @compileError("bad tuple 0");
        if (!std.mem.eql(u8, router.routeConst(1).pattern, @field(tuple, fields[1].name).pattern)) @compileError("bad tuple 1");

        router.clear();
        break :blk .{
            .cleared_count = router.count(),
            .cleared_len = router.all().len,
        };
    };

    try std.testing.expectEqual(@as(usize, 0), Result.cleared_count);
    try std.testing.expectEqual(@as(usize, 0), Result.cleared_len);
}
