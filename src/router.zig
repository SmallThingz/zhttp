const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Res = @import("response.zig").Res;
const parse = @import("parse.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const urldecode = @import("urldecode.zig");
const util = @import("util.zig");
const middleware = @import("middleware.zig");
const req_ctx = @import("req_ctx.zig");
const ReqCtx = req_ctx.ReqCtx;

comptime {
    @setEvalBranchQuota(30000);
}

pub const Action = enum {
    @"continue",
    close,
    upgraded,
};

/// Route options passed at comptime to `route`, `get`, `post`, etc.
///
/// Any struct with a subset of these fields is accepted:
/// - `headers: type`  Request header captures (see `zhttp.parse.*` parsers)
/// - `query: type`    Query-string captures
/// - `params: type`   Path param captures (parsed from `{name}` and `{*name}` segments)
/// - `middlewares: tuple` Per-route middleware types (same `call(...)` interface as global middlewares)
///
/// Notes:
/// - Captures are *types* (e.g. `struct { id: zhttp.parse.Int(u64) }`), not values.
/// - Header keys are normalized: `_` in field names matches `-` in header names.
/// - Query keys are exact (case-sensitive).
fn validateRouteOptions(comptime opts: anytype) void {
    const OptT = @TypeOf(opts);
    const info = @typeInfo(OptT);
    if (info != .@"struct") @compileError("route options must be a struct literal");

    inline for (info.@"struct".fields) |f| {
        const name0 = f.name;
        const name: []const u8 = name0[0..name0.len];
        comptime {
            const allowed = std.mem.eql(u8, name, "headers") or
                std.mem.eql(u8, name, "query") or
                std.mem.eql(u8, name, "params") or
                std.mem.eql(u8, name, "middlewares") or
                std.mem.eql(u8, name, "upgrade_handler");
            if (!allowed) @compileError("unknown route option: " ++ name);

            if (std.mem.eql(u8, name, "headers") or std.mem.eql(u8, name, "query") or std.mem.eql(u8, name, "params")) {
                if (@TypeOf(@field(opts, name0)) != type) {
                    @compileError("route option '" ++ name ++ "' must be a type (e.g. .{" ++ name ++ " = struct { ... } })");
                }
            } else if (std.mem.eql(u8, name, "middlewares")) {
                const mw = @field(opts, name0);
                const mw_info = @typeInfo(@TypeOf(mw));
                if (mw_info != .@"struct" or !mw_info.@"struct".is_tuple) {
                    @compileError("route option 'middlewares' must be a tuple (e.g. .{ .middlewares = .{Mw1, Mw2} })");
                }
            } else if (std.mem.eql(u8, name, "upgrade_handler")) {
                const h = @field(opts, name0);
                const ht = @TypeOf(h);
                if (ht == @TypeOf(null)) continue;
                const h_info = @typeInfo(ht);
                if (h_info == .@"fn") continue;
                if (h_info == .optional and @typeInfo(h_info.optional.child) == .@"fn") continue;
                @compileError("route option 'upgrade_handler' must be fn(...) void, ?fn(...) void, or null");
            }
        }
    }
}

pub const RouteDecl = struct {
    /// Stores `method`.
    method: []const u8,
    /// Stores `pattern`.
    pattern: []const u8,
    /// Stores endpoint type exposing `pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res`.
    endpoint: type,
    /// Stores `headers`.
    headers: type,
    /// Stores `query`.
    query: type,
    /// Stores `params`.
    params: type,
    /// Stores `middlewares`.
    middlewares: []const type,
    // Bridge type carrying `pub const value = null|fn|?fn`.
    /// Stores `upgrade_handler`.
    upgrade_handler: type,
};

fn endpointType(comptime endpoint: type) type {
    if (!@hasDecl(endpoint, "call")) {
        @compileError("route endpoint type must expose `pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res`");
    }
    return endpoint;
}

fn tupleToTypeList(comptime t: anytype) []const type {
    const info = @typeInfo(@TypeOf(t));
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("route option 'middlewares' must be a tuple (e.g. .{ .middlewares = .{Mw1, Mw2} })");
    }
    const fields = info.@"struct".fields;
    if (fields.len == 0) return &.{};
    const out: [fields.len]type = comptime blk: {
        var tmp: [fields.len]type = undefined;
        for (fields, 0..) |f, i| {
            tmp[i] = @field(t, f.name);
        }
        break :blk tmp;
    };
    return out[0..];
}

/// Implements route.
pub fn route(
    /// HTTP method enum literal, e.g. `.GET`.
    comptime method_lit: @EnumLiteral(),
    comptime pattern: []const u8,
    /// Route endpoint type exposing `pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res`.
    comptime endpoint: type,
    /// Route options (see `zhttp/root.zig` docs). Use `.{}` for none.
    comptime opts: anytype,
) RouteDecl {
    validateRouteOptions(opts);
    const OptT = @TypeOf(opts);
    const Endpoint = endpointType(endpoint);
    const UpgradeHandlerBridge = struct {
        pub const value = if (@hasField(OptT, "upgrade_handler")) opts.upgrade_handler else null;
    };
    return .{
        .method = @tagName(method_lit),
        .pattern = pattern,
        .endpoint = Endpoint,
        .headers = if (@hasField(OptT, "headers")) opts.headers else struct {},
        .query = if (@hasField(OptT, "query")) opts.query else struct {},
        .params = if (@hasField(OptT, "params")) opts.params else struct {},
        .middlewares = if (@hasField(OptT, "middlewares")) tupleToTypeList(opts.middlewares) else &.{},
        .upgrade_handler = UpgradeHandlerBridge,
    };
}

/// Implements get.
pub fn get(comptime pattern: []const u8, comptime endpoint: type, comptime opts: anytype) RouteDecl {
    return route(.GET, pattern, endpoint, opts);
}
/// Implements post.
pub fn post(comptime pattern: []const u8, comptime endpoint: type, comptime opts: anytype) RouteDecl {
    return route(.POST, pattern, endpoint, opts);
}
/// Implements put.
pub fn put(comptime pattern: []const u8, comptime endpoint: type, comptime opts: anytype) RouteDecl {
    return route(.PUT, pattern, endpoint, opts);
}
/// Implements delete.
pub fn delete(comptime pattern: []const u8, comptime endpoint: type, comptime opts: anytype) RouteDecl {
    return route(.DELETE, pattern, endpoint, opts);
}
/// Implements patch.
pub fn patch(comptime pattern: []const u8, comptime endpoint: type, comptime opts: anytype) RouteDecl {
    return route(.PATCH, pattern, endpoint, opts);
}
/// Implements head.
pub fn head(comptime pattern: []const u8, comptime endpoint: type, comptime opts: anytype) RouteDecl {
    return route(.HEAD, pattern, endpoint, opts);
}
/// Implements options.
pub fn options(comptime pattern: []const u8, comptime endpoint: type, comptime opts: anytype) RouteDecl {
    return route(.OPTIONS, pattern, endpoint, opts);
}

fn tupleConcatValuesType(comptime a: anytype, comptime b: anytype) type {
    const la: usize = comptime util.tupleLen(a);
    const lb: usize = comptime util.tupleLen(b);
    if (la == 0) return @TypeOf(b);
    if (lb == 0) return @TypeOf(a);
    const OutFieldTypes = comptime blk: {
        var out: [la + lb]type = undefined;
        for (@typeInfo(@TypeOf(a)).@"struct".fields, 0..) |f, i| {
            out[i] = @TypeOf(@field(a, f.name));
        }
        for (@typeInfo(@TypeOf(b)).@"struct".fields, 0..) |f, i| {
            out[la + i] = @TypeOf(@field(b, f.name));
        }
        break :blk out;
    };
    return std.meta.Tuple(&OutFieldTypes);
}

fn tupleConcatValues(comptime a: anytype, comptime b: anytype) tupleConcatValuesType(a, b) {
    const la: usize = comptime util.tupleLen(a);
    const lb: usize = comptime util.tupleLen(b);
    if (la == 0) return b;
    if (lb == 0) return a;

    const OutT = tupleConcatValuesType(a, b);
    return comptime blk: {
        var out: OutT = undefined;
        for (@typeInfo(@TypeOf(a)).@"struct".fields, 0..) |f, i| {
            @field(out, std.fmt.comptimePrint("{d}", .{i})) = @field(a, f.name);
        }
        for (@typeInfo(@TypeOf(b)).@"struct".fields, 0..) |f, i| {
            @field(out, std.fmt.comptimePrint("{d}", .{la + i})) = @field(b, f.name);
        }
        break :blk out;
    };
}

fn assertNoDuplicateRoutes(comptime routes: anytype) void {
    const fields = @typeInfo(@TypeOf(routes)).@"struct".fields;
    inline for (fields, 0..) |f, i| {
        const r = @field(routes, f.name);
        inline for (fields[0..i]) |pf| {
            const pr = @field(routes, pf.name);
            if (comptime std.mem.eql(u8, r.method, pr.method) and std.mem.eql(u8, r.pattern, pr.pattern)) {
                @compileError("duplicate route: " ++ r.method ++ " " ++ r.pattern);
            }
        }
    }
}

fn assertNoRouteCollisions(comptime a: anytype, comptime b: anytype) void {
    const fa = @typeInfo(@TypeOf(a)).@"struct".fields;
    const fb = @typeInfo(@TypeOf(b)).@"struct".fields;
    inline for (fa) |f| {
        const ra = @field(a, f.name);
        inline for (fb) |g| {
            const rb = @field(b, g.name);
            if (comptime std.mem.eql(u8, ra.method, rb.method) and std.mem.eql(u8, ra.pattern, rb.pattern)) {
                @compileError("route collision: " ++ ra.method ++ " " ++ ra.pattern);
            }
        }
    }
}

fn mergeRoutesType(comptime user_routes: anytype, comptime extra_routes: anytype) type {
    if (util.tupleLen(extra_routes) == 0) return @TypeOf(user_routes);
    const a: @TypeOf(user_routes) = undefined;
    const b: @TypeOf(extra_routes) = undefined;
    return tupleConcatValuesType(a, b);
}

/// Implements merge routes.
pub fn mergeRoutes(comptime user_routes: anytype, comptime extra_routes: anytype) mergeRoutesType(user_routes, extra_routes) {
    if (util.tupleLen(extra_routes) == 0) return user_routes;
    assertNoDuplicateRoutes(extra_routes);
    assertNoRouteCollisions(user_routes, extra_routes);
    return tupleConcatValues(user_routes, extra_routes);
}

fn structFieldsToST(comptime T: type) []const req_ctx.ST {
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len == 0) return &.{};
    const out = comptime blk: {
        var tmp: [fields.len]req_ctx.ST = undefined;
        for (fields, 0..) |f, i| {
            tmp[i] = .{ .name = f.name, .T = f.type };
        }
        break :blk tmp;
    };
    return out[0..];
}

const SegmentKind = enum { lit, param, glob, glob_param };
const Segment = struct {
    /// Stores `kind`.
    kind: SegmentKind,
    /// Stores `lit`.
    lit: []const u8 = "",
    /// Stores `param_index`.
    param_index: u8 = 0,
};

const Pattern = struct {
    /// Stores `segments`.
    segments: []const Segment,
    /// Stores `param_names`.
    param_names: []const []const u8,
    /// Stores `glob`.
    glob: bool,
};

fn compilePattern(comptime pattern: []const u8) Pattern {
    if (pattern.len == 0 or pattern[0] != '/') @compileError("route pattern must start with '/'");

    if (std.mem.eql(u8, pattern, "/")) {
        return .{ .segments = &.{}, .param_names = &.{}, .glob = false };
    }

    // Count segments and params.
    comptime var seg_count: usize = 0;
    comptime var param_count: usize = 0;
    comptime var glob: bool = false;

    comptime {
        var start: usize = 1;
        while (start <= pattern.len) {
            const end = std.mem.indexOfScalarPos(u8, pattern, start, '/') orelse pattern.len;
            const seg = pattern[start..end];
            if (seg.len == 0) @compileError("empty path segments are not supported");
            seg_count += 1;
            if (std.mem.eql(u8, seg, "*")) {
                if (end != pattern.len) @compileError("glob '*' is only allowed as the last segment");
                glob = true;
            } else if (seg[0] == '{') {
                if (seg[seg.len - 1] != '}') @compileError("param segment must end with '}'");
                const inner = seg[1 .. seg.len - 1];
                if (inner.len == 0) @compileError("param name cannot be empty");
                if (inner[0] == '*') {
                    if (inner.len < 2) @compileError("glob param name cannot be empty");
                    if (end != pattern.len) @compileError("named glob '{*name}' is only allowed as the last segment");
                    glob = true;
                } else if (std.mem.indexOfScalar(u8, inner, '*') != null) {
                    @compileError("'*' is only allowed as '{*name}' for named trailing globs");
                }
                param_count += 1;
            } else {
                if (std.mem.indexOfScalar(u8, seg, '*') != null) @compileError("'*' is only allowed as a full segment at the end");
            }
            start = end + 1;
            if (end == pattern.len) break;
        }
    }

    const seg_arr: [seg_count]Segment = comptime blk: {
        var segs: [seg_count]Segment = undefined;
        var pi: u8 = 0;
        var si: usize = 0;
        var s: usize = 1;
        while (s <= pattern.len) {
            const e = std.mem.indexOfScalarPos(u8, pattern, s, '/') orelse pattern.len;
            const seg = pattern[s..e];
            if (std.mem.eql(u8, seg, "*")) {
                segs[si] = .{ .kind = .glob };
            } else if (seg[0] == '{') {
                const inner = seg[1 .. seg.len - 1];
                if (inner[0] == '*') {
                    segs[si] = .{ .kind = .glob_param, .param_index = pi };
                } else {
                    segs[si] = .{ .kind = .param, .param_index = pi };
                }
                pi += 1;
            } else {
                segs[si] = .{ .kind = .lit, .lit = seg };
            }
            si += 1;
            s = e + 1;
            if (e == pattern.len) break;
        }
        break :blk segs;
    };

    const names_arr: [param_count][]const u8 = comptime blk: {
        var names: [param_count][]const u8 = undefined;
        var pi: usize = 0;
        var s: usize = 1;
        while (s <= pattern.len) {
            const e = std.mem.indexOfScalarPos(u8, pattern, s, '/') orelse pattern.len;
            const seg = pattern[s..e];
            if (seg.len != 0 and seg[0] == '{') {
                const inner = seg[1 .. seg.len - 1];
                if (inner[0] == '*') {
                    names[pi] = inner[1..];
                } else {
                    names[pi] = inner;
                }
                pi += 1;
            }
            s = e + 1;
            if (e == pattern.len) break;
        }
        break :blk names;
    };

    comptime {
        // Duplicate param names would make typed `.params` ambiguous.
        for (names_arr, 0..) |a, i| {
            for (names_arr[0..i]) |b| {
                if (std.mem.eql(u8, a, b)) {
                    @compileError("duplicate route param name '" ++ a ++ "'");
                }
            }
        }
    }

    return .{ .segments = seg_arr[0..], .param_names = names_arr[0..], .glob = glob };
}

fn matchPattern(p: Pattern, path: []u8, params_out: [][]u8) bool {
    if (p.segments.len == 0) return path.len == 1 and path[0] == '/';
    var path_i: usize = 0;
    if (path.len == 0 or path[0] != '/') return false;
    path_i = 1;

    var seg_index: usize = 0;
    while (seg_index < p.segments.len) : (seg_index += 1) {
        const seg = p.segments[seg_index];
        if (seg.kind == .glob) {
            return true;
        }
        if (seg.kind == .glob_param) {
            params_out[seg.param_index] = if (path_i <= path.len) path[path_i..] else path[path.len..path.len];
            return true;
        }

        if (path_i > path.len) return false;
        const next_slash = std.mem.indexOfScalarPos(u8, path, path_i, '/') orelse path.len;
        const part = path[path_i..next_slash];
        if (part.len == 0) return false;

        switch (seg.kind) {
            .lit => {
                if (!std.mem.eql(u8, part, seg.lit)) return false;
            },
            .param => {
                params_out[seg.param_index] = part;
            },
            .glob => unreachable,
            .glob_param => unreachable,
        }

        path_i = if (next_slash == path.len) path.len + 1 else next_slash + 1;
    }

    // Must have consumed entire path (no extra segments) unless glob was used.
    return path_i >= path.len + 1;
}

fn matchPatternNoCapture(p: Pattern, path: []u8) bool {
    if (p.segments.len == 0) return path.len == 1 and path[0] == '/';
    var path_i: usize = 0;
    if (path.len == 0 or path[0] != '/') return false;
    path_i = 1;

    var seg_index: usize = 0;
    while (seg_index < p.segments.len) : (seg_index += 1) {
        const seg = p.segments[seg_index];
        if (seg.kind == .glob or seg.kind == .glob_param) {
            return true;
        }

        if (path_i > path.len) return false;
        const next_slash = std.mem.indexOfScalarPos(u8, path, path_i, '/') orelse path.len;
        const part = path[path_i..next_slash];
        if (part.len == 0) return false;

        switch (seg.kind) {
            .lit => {
                if (!std.mem.eql(u8, part, seg.lit)) return false;
            },
            .param => {},
            .glob => unreachable,
            .glob_param => unreachable,
        }

        path_i = next_slash + 1;
    }

    return path_i > path.len;
}

fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn nextPow2AtLeast(comptime n: usize, comptime min: usize) usize {
    var x: usize = if (n < min) min else n;
    x -= 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    if (@sizeOf(usize) == 8) x |= x >> 32;
    return x + 1;
}

const ExactEntry = struct {
    /// Stores `path`.
    path: []const u8,
    /// Stores `hash`.
    hash: u64,
    /// Stores `route_index`.
    route_index: u16,
};

fn ExactMap(comptime entries: anytype, comptime n: usize) type {
    const EntriesT = @TypeOf(entries);
    comptime {
        const info = @typeInfo(EntriesT);
        if (info != .array or info.array.child != ExactEntry) {
            @compileError("ExactMap entries must be an array of ExactEntry");
        }
    }

    const cap: usize = nextPow2AtLeast(n * 2 + 1, 8);
    const table = comptime blk: {
        var t: [cap]u16 = .{0} ** cap;
        const mask: u64 = cap - 1;
        for (0..n) |ei| {
            const e = entries[ei];
            var pos: u64 = e.hash & mask;
            while (true) : (pos = (pos + 1) & mask) {
                if (t[@intCast(pos)] == 0) {
                    t[@intCast(pos)] = @intCast(ei + 1);
                    break;
                }
            }
        }
        break :blk t;
    };

    return struct {
        /// Implements find.
        pub fn find(path: []const u8) ?u16 {
            if (n == 0) return null;
            const h = fnv1a64(path);
            const mask: u64 = cap - 1;
            var pos: u64 = h & mask;
            var probe: usize = 0;
            while (probe < cap) : (probe += 1) {
                const slot = table[@intCast(pos)];
                if (slot == 0) return null;
                const ei: usize = slot - 1;
                const e = entries[ei];
                if (e.hash == h and std.mem.eql(u8, e.path, path)) {
                    return e.route_index;
                }
                pos = (pos + 1) & mask;
            }
            return null;
        }
    };
}

/// Implements compiled.
pub fn Compiled(
    comptime _: type,
    comptime routes: anytype,
    comptime global_middlewares: anytype,
) type {
    const RoutesType = @TypeOf(routes);
    const routes_info = @typeInfo(RoutesType);
    if (routes_info != .@"struct" or !routes_info.@"struct".is_tuple) @compileError("routes must be a tuple");
    const route_fields = routes_info.@"struct".fields;
    const route_count = route_fields.len;
    const global_mw_list = comptime middleware.typeList(global_middlewares);

    const RouterBuilder = struct {
        const Self = @This();

        patterns: [route_count]Pattern = undefined,
        max_params: usize = 0,
        method_names: [route_count][]const u8 = undefined,
        method_count: usize = 0,
        route_method_ids: [route_count]u8 = undefined,

        fn ensureMethodId(self: *Self, method: []const u8) u8 {
            var i: usize = 0;
            while (i < self.method_count) : (i += 1) {
                if (std.mem.eql(u8, self.method_names[i], method)) return @intCast(i);
            }
            self.method_names[self.method_count] = method;
            const id: u8 = @intCast(self.method_count);
            self.method_count += 1;
            return id;
        }

        fn addRoute(self: *Self, comptime route_index: usize, rd: anytype) void {
            if (!@hasField(@TypeOf(rd), "method") or !@hasField(@TypeOf(rd), "pattern") or !@hasField(@TypeOf(rd), "endpoint")) {
                @compileError("route() value must have fields: method, pattern, endpoint");
            }

            self.patterns[route_index] = compilePattern(rd.pattern);
            if (self.patterns[route_index].param_names.len > self.max_params) {
                self.max_params = self.patterns[route_index].param_names.len;
            }
            self.route_method_ids[route_index] = self.ensureMethodId(rd.method);
        }

        fn compile(
            comptime self: Self,
            comptime routes_value: anytype,
            comptime fields: anytype,
        ) struct {
            patterns: [route_count]Pattern,
            max_params: usize,
            method_names: [route_count][]const u8,
            method_count: usize,
            route_method_ids: [route_count]u8,
            exact_storage: [self.method_count][route_count]ExactEntry,
            exact_counts: [self.method_count]usize,
            pattern_storage: [self.method_count][route_count]u16,
            pattern_counts: [self.method_count]usize,
        } {
            const method_count: usize = self.method_count;
            var exact_storage: [method_count][route_count]ExactEntry = undefined;
            var exact_counts: [method_count]usize = .{0} ** method_count;
            var pattern_storage: [method_count][route_count]u16 = undefined;
            var pattern_counts: [method_count]usize = .{0} ** method_count;

            for (0..method_count) |mid| {
                const mid_u8: u8 = @intCast(mid);
                var exact_n: usize = 0;
                var pat_n: usize = 0;

                for (fields, 0..) |f, i| {
                    if (self.route_method_ids[i] != mid_u8) continue;
                    const rd = @field(routes_value, f.name);
                    const p = self.patterns[i];
                    const exact = p.param_names.len == 0 and
                        !p.glob and
                        std.mem.indexOfScalar(u8, rd.pattern, '{') == null and
                        std.mem.indexOfScalar(u8, rd.pattern, '*') == null;
                    if (exact) {
                        exact_storage[mid][exact_n] = .{
                            .path = rd.pattern,
                            .hash = fnv1a64(rd.pattern),
                            .route_index = @intCast(i),
                        };
                        exact_n += 1;
                    } else {
                        pattern_storage[mid][pat_n] = @intCast(i);
                        pat_n += 1;
                    }
                }

                exact_counts[mid] = exact_n;
                pattern_counts[mid] = pat_n;
            }

            return .{
                .patterns = self.patterns,
                .max_params = self.max_params,
                .method_names = self.method_names,
                .method_count = method_count,
                .route_method_ids = self.route_method_ids,
                .exact_storage = exact_storage,
                .exact_counts = exact_counts,
                .pattern_storage = pattern_storage,
                .pattern_counts = pattern_counts,
            };
        }
    };

    const compiled = comptime blk: {
        var router = RouterBuilder{};
        for (route_fields, 0..) |f, i| {
            router.addRoute(i, @field(routes, f.name));
        }
        break :blk router.compile(routes, route_fields);
    };

    const method_count: usize = compiled.method_count;
    const single_method: []const u8 = if (route_count == 1) compiled.method_names[@as(usize, compiled.route_method_ids[0])] else "";
    const single_pattern: []const u8 = if (route_count == 1) @field(routes, route_fields[0].name).pattern else "";
    const single_exact: bool = route_count == 1 and
        compiled.patterns[0].param_names.len == 0 and
        !compiled.patterns[0].glob and
        std.mem.indexOfScalar(u8, single_pattern, '{') == null and
        std.mem.indexOfScalar(u8, single_pattern, '*') == null;

    const head_id: ?u8 = comptime blk: {
        const Methods0 = compiled.method_names[0..compiled.method_count];
        var out: ?u8 = null;
        for (Methods0, 0..) |m, i| {
            if (std.mem.eql(u8, m, "HEAD")) {
                out = @intCast(i);
                break;
            }
        }
        break :blk out;
    };
    const get_id: ?u8 = comptime blk: {
        const Methods0 = compiled.method_names[0..compiled.method_count];
        var out: ?u8 = null;
        for (Methods0, 0..) |m, i| {
            if (std.mem.eql(u8, m, "GET")) {
                out = @intCast(i);
                break;
            }
        }
        break :blk out;
    };

    const all_method_ids: [method_count]u8 = comptime blk: {
        var out: [method_count]u8 = undefined;
        for (0..method_count) |i| out[i] = @intCast(i);
        break :blk out;
    };

    return struct {
        pub const RouteCount: usize = route_count;
        pub const MaxParams: usize = compiled.max_params;
        pub const DispatchError = error{
            EndOfStream,
            ReadFailed,
            WriteFailed,
            HeadersTooLarge,
            MissingRequired,
            BadValue,
            InvalidPercentEncoding,
            BadRequest,
            StreamTooLong,
            OutOfMemory,
        };
        pub const RouteParamCounts: [route_count]usize = blk: {
            var out: [route_count]usize = undefined;
            for (route_fields, 0..) |_, i| {
                out[i] = compiled.patterns[i].param_names.len;
            }
            break :blk out;
        };

        fn pack4(s: []const u8, offset: usize) u32 {
            var v: u32 = 0;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const idx = offset + i;
                const b: u8 = if (idx < s.len) s[idx] else 0;
                v |= (@as(u32, b) << @intCast(i * 8));
            }
            return v;
        }

        fn maxLenForIds(comptime ids: []const u8) usize {
            var m: usize = 0;
            for (ids) |id| {
                const len = compiled.method_names[@as(usize, id)].len;
                if (len > m) m = len;
            }
            return m;
        }

        fn uniqueKeys(comptime ids: []const u8, comptime offset: usize) struct { keys: [ids.len]u32, len: usize } {
            var out: [ids.len]u32 = undefined;
            var n: usize = 0;
            for (ids) |id| {
                const k = pack4(compiled.method_names[@as(usize, id)], offset);
                var found = false;
                for (out[0..n]) |e| {
                    if (e == k) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    out[n] = k;
                    n += 1;
                }
            }
            return .{ .keys = out, .len = n };
        }

        fn filterIds(comptime ids: []const u8, comptime offset: usize, comptime key: u32) struct { ids: [ids.len]u8, len: usize } {
            var out: [ids.len]u8 = undefined;
            var n: usize = 0;
            for (ids) |id| {
                const k = pack4(compiled.method_names[@as(usize, id)], offset);
                if (k == key) {
                    out[n] = id;
                    n += 1;
                }
            }
            return .{ .ids = out, .len = n };
        }

        fn matchMethod(comptime mid: u8, path: []u8) ?u16 {
            const mid_usize: usize = mid;
            const Exact = ExactMap(compiled.exact_storage[mid_usize], compiled.exact_counts[mid_usize]);
            if (Exact.find(path)) |rid| return rid;

            const n: usize = compiled.pattern_counts[mid_usize];
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const rid = compiled.pattern_storage[mid_usize][j];
                const p = compiled.patterns[rid];
                if (matchPatternNoCapture(p, path)) return rid;
            }
            return null;
        }

        fn eqLiteral(bytes: []const u8, comptime lit: []const u8) bool {
            if (bytes.len != lit.len) return false;
            inline for (lit, 0..) |c, i| {
                if (bytes[i] != c) return false;
            }
            return true;
        }

        fn dispatchByMethod(
            comptime ids: []const u8,
            comptime offset: usize,
            method_token: []const u8,
            path: []u8,
        ) ?u16 {
            if (ids.len == 0) return null;
            if (ids.len == 1) {
                const mid: u8 = ids[0];
                const name: []const u8 = compiled.method_names[@as(usize, mid)];
                if (!std.mem.eql(u8, method_token, name)) return null;
                return matchMethod(mid, path);
            }

            if (offset >= comptime maxLenForIds(ids)) {
                inline for (ids) |mid| {
                    const name: []const u8 = compiled.method_names[@as(usize, mid)];
                    if (std.mem.eql(u8, method_token, name)) {
                        return matchMethod(mid, path);
                    }
                }
                return null;
            }

            const key = pack4(method_token, offset);
            const keys = comptime uniqueKeys(ids, offset);
            inline for (keys.keys[0..keys.len]) |kcase| {
                if (key == kcase) {
                    const sub = comptime filterIds(ids, offset, kcase);
                    return dispatchByMethod(sub.ids[0..sub.len], offset + 4, method_token, path);
                }
            }
            return null;
        }

        /// Implements match.
        pub fn match(method_token: []const u8, path: []u8) ?u16 {
            if (single_exact) {
                if (eqLiteral(method_token, "HEAD")) {
                    if (eqLiteral(single_method, "HEAD") or eqLiteral(single_method, "GET")) {
                        if (eqLiteral(path, single_pattern)) return 0;
                    }
                    return null;
                }
                if (!eqLiteral(method_token, single_method)) return null;
                if (!eqLiteral(path, single_pattern)) return null;
                return 0;
            }
            // HEAD fallback to GET.
            if (std.mem.eql(u8, method_token, "HEAD")) {
                if (head_id) |hid| {
                    if (matchMethod(hid, path)) |rid| return rid;
                }
                if (get_id) |gid| {
                    return matchMethod(gid, path);
                }
                return null;
            }

            return dispatchByMethod(all_method_ids[0..], 0, method_token, path);
        }

        fn captureParams(route_index: u16, path: []u8, params_out: [][]u8) bool {
            inline for (route_fields, 0..) |_, i| {
                if (route_index == i) {
                    return matchPattern(compiled.patterns[i], path, params_out);
                }
            }
            return false;
        }

        fn finishResponse(w: *Io.Writer, res: Res, keep_alive: bool, send_body: bool) !Action {
            try response.write(w, res, keep_alive, send_body);
            if (w.buffered().len != 0) {
                try w.flush();
            }
            return if (!keep_alive or res.close) .close else .@"continue";
        }

        fn callUpgradeHandler(
            comptime handler: anytype,
            server: anytype,
            stream: *const std.Io.net.Stream,
            r: *Io.Reader,
            w: *Io.Writer,
            line: request.RequestLine,
            res: Res,
        ) void {
            const HandlerT = @TypeOf(handler);
            const h_info = @typeInfo(HandlerT);
            if (h_info != .@"fn") @compileError("upgrade_handler must be a function");
            if (h_info.@"fn".return_type != void) @compileError("upgrade_handler must return void");
            if (h_info.@"fn".params.len != 6) {
                @compileError("upgrade_handler must be fn(server, stream, r, w, line, res) void");
            }
            @call(.auto, handler, .{ server, stream, r, w, line, res });
        }

        fn maybeHandleUpgrade(
            comptime maybe_upgrade: anytype,
            server: anytype,
            stream: *const std.Io.net.Stream,
            r: *Io.Reader,
            w: *Io.Writer,
            line: request.RequestLine,
            res: Res,
        ) DispatchError!?Action {
            if (@TypeOf(maybe_upgrade) == @TypeOf(null)) return null;

            if (@typeInfo(@TypeOf(maybe_upgrade)) == .optional) {
                if (maybe_upgrade) |upgrade_handler| {
                    if (res.status == .switching_protocols) {
                        try response.writeUpgrade(w, res);
                        if (w.buffered().len != 0) try w.flush();
                        callUpgradeHandler(upgrade_handler, server, stream, r, w, line, res);
                        return .upgraded;
                    }
                }
                return null;
            }

            if (res.status == .switching_protocols) {
                try response.writeUpgrade(w, res);
                if (w.buffered().len != 0) try w.flush();
                callUpgradeHandler(maybe_upgrade, server, stream, r, w, line, res);
                return .upgraded;
            }
            return null;
        }

        /// Implements dispatch.
        pub fn dispatch(
            server: anytype,
            allocator: Allocator,
            r: *Io.Reader,
            w: *Io.Writer,
            stream: *const std.Io.net.Stream,
            route_static_ctx: *anyopaque,
            line: request.RequestLine,
            route_index: u16,
            params_buf: [][]u8,
            max_header_bytes: usize,
        ) DispatchError!Action {
            inline for (route_fields, 0..) |f, i| {
                if (route_index == i) {
                    const rd = @field(routes, f.name);
                    const p = compiled.patterns[i];
                    const MwList = comptime middleware.concatTypeLists(global_mw_list, rd.middlewares);
                    const NeedH = comptime middleware.needsHeaders(MwList);
                    const NeedQ = comptime middleware.needsQuery(MwList);
                    const NeedP = comptime middleware.needsParams(MwList);
                    const H = parse.mergeHeaderStructs(NeedH, rd.headers);
                    const Q = parse.mergeStructs(NeedQ, rd.query);
                    const P = parse.mergeStructs(NeedP, rd.params);
                    const MwCtx = comptime middleware.contextType(MwList);
                    const mw_ctx = comptime middleware.initContext(MwList, MwCtx);
                    const MwStaticCtx = comptime middleware.staticContextType(MwList);
                    const route_mw_static_ctx: *MwStaticCtx = @ptrCast(@alignCast(route_static_ctx));
                    const ReqT = request.RequestPWithPatternCtxStatic(H, Q, P, p.param_names, MwCtx, MwStaticCtx, rd.pattern, rd.method, @TypeOf(server.ctx));
                    const ReqCtxT = req_ctx.ReqCtx;
                    const EndpointBridge = struct {
                        pub const function = rd.endpoint.call;
                    };
                    const rctx: ReqCtxT = comptime .{
                        .handler = EndpointBridge,
                        .middlewares = MwList,
                        .path = structFieldsToST(P),
                        .query = structFieldsToST(Q),
                        .headers = structFieldsToST(H),
                        .middleware_contexts = middleware.contextST(MwList),
                        .idx = 0,
                        ._base_req_type = ReqT,
                    };

                    var reqv = ReqT.initWithCtx(allocator, server.io, line, mw_ctx, server.ctx, route_mw_static_ctx);
                    reqv.setReader(r);
                    defer reqv.deinit(allocator);
                    errdefer reqv.discardUnreadBody() catch {};
                    if (p.param_names.len != 0) {
                        std.debug.assert(captureParams(route_index, line.path, params_buf));
                        inline for (p.param_names, 0..) |_, pidx| {
                            params_buf[pidx] = try urldecode.decodeInPlace(params_buf[pidx], .path_param);
                        }
                        const decoded_params: []const []u8 = params_buf[0..p.param_names.len];
                        try reqv.parseParams(allocator, decoded_params);
                    }
                    if (parse.structFields(Q).len != 0) {
                        try reqv.parseQuery(allocator, line.query);
                    }

                    try reqv.parseHeaders(allocator, r, max_header_bytes);

                    const req0: rctx.T() = .{
                        ._base = &reqv,
                        .path = line.path,
                        .method = line.method,
                    };
                    const res = rctx.run(req0) catch |err| {
                        reqv.discardUnreadBody() catch return .close;
                        const ServerT = @TypeOf(server.*);
                        return ServerT.handleHandlerError(server, w, @TypeOf(err), err);
                    };

                    // Ensure unread body is discarded before next request.
                    try reqv.discardUnreadBody();
                    if (try maybeHandleUpgrade(rd.upgrade_handler.value, server, stream, r, w, line, res)) |act| return act;
                    const send_body = !(line.method.len == 4 and line.method[0] == 'H' and line.method[1] == 'E' and line.method[2] == 'A' and line.method[3] == 'D');
                    return finishResponse(w, res, reqv.keepAlive(), send_body);
                }
            }
            return error.BadRequest;
        }
    };
}

test "compilePattern glob only at end" {
    _ = compilePattern("/a/*");
    _ = compilePattern("/a/{*rest}");
}

fn dispatchForTest(
    comptime S: type,
    ctx: anytype,
    allocator: Allocator,
    r: *Io.Reader,
    line: request.RequestLine,
    out: []u8,
) !struct { action: Action, len: usize } {
    const ServerT = struct {
        /// Stores `io`.
        io: Io,
        /// Stores `ctx`.
        ctx: @TypeOf(ctx),

        /// Implements handle handler error.
        pub fn handleHandlerError(_: *@This(), _: *Io.Writer, comptime _: type, _: anytype) Action {
            unreachable;
        }
    };
    var server: ServerT = .{
        .io = std.testing.io,
        .ctx = ctx,
    };
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out);
    var stream: std.Io.net.Stream = undefined;
    var route_static_ctx: struct {} = .{};
    const rid = S.match(line.method, line.path).?;
    const action = try S.dispatch(&server, allocator, r, &w, &stream, @ptrCast(&route_static_ctx), line, rid, params[0..S.MaxParams], 8 * 1024);
    return .{ .action = action, .len = w.end };
}

test "router: exact + param + glob" {
    const App = struct {};
    const S = Compiled(App, .{
        get("/a", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "a");
            }
        }, .{}),
        get("/u/{id}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "u");
            }
        }, .{}),
        get("/g/*", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "g");
            }
        }, .{}),
        get("/ng/{*rest}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "ng");
            }
        }, .{}),
    }, .{});

    var p0 = "/a".*;
    try std.testing.expectEqual(@as(?u16, 0), S.match("GET", p0[0..]));

    var p1 = "/u/123".*;
    try std.testing.expectEqual(@as(?u16, 1), S.match("GET", p1[0..]));

    var p2 = "/g/anything/here".*;
    try std.testing.expectEqual(@as(?u16, 2), S.match("GET", p2[0..]));

    var p3 = "/ng/a/b/c".*;
    try std.testing.expectEqual(@as(?u16, 3), S.match("GET", p3[0..]));

    var p4 = "/ng".*;
    try std.testing.expectEqual(@as(?u16, 3), S.match("GET", p4[0..]));
}

test "router: trailing slash does not match exact literal" {
    const S = Compiled(void, .{
        get("/a", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "a");
            }
        }, .{}),
    }, .{});

    var p1 = "/a/".*;
    try std.testing.expectEqual(@as(?u16, null), S.match("GET", p1[0..]));
}

test "router: HEAD falls back to GET handler" {
    const S = Compiled(void, .{
        get("/x", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }, .{}),
    }, .{});

    var p = "/x".*;
    try std.testing.expectEqual(@as(?u16, 0), S.match("HEAD", p[0..]));
}

test "middleware Info: supports 'header: type = ...' form" {
    const Mw = struct {
        pub const Info = @import("middleware.zig").MiddlewareInfo{
            .name = "mw_needs",
            .header = struct {
                /// Stores `host`.
                host: parse.Optional(parse.String),
            },
            .query = struct {},
        };

        /// Handles a middleware invocation for the current request context.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            return rctx.next(req);
        }
    };

    _ = Compiled(void, .{
        get("/x", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "x");
            }
        }, .{}),
    }, .{Mw});
}

test "middleware Info: supports header/query/path/data captures" {
    const Mw = struct {
        const AuthData = struct {
            /// Stores `seen`.
            seen: bool = false,
        };
        pub const Info = @import("middleware.zig").MiddlewareInfo{
            .name = "auth",
            .data = AuthData,
            .path = struct {
                /// Stores `id`.
                id: parse.Int(u32),
            },
            .query = struct {
                /// Stores `q`.
                q: parse.String,
            },
            .header = struct {
                /// Stores `x_token`.
                x_token: parse.String,
            },
        };

        /// Handles a middleware invocation for the current request context.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            if (req.paramValue(.id) != 7) return Res.text(500, "bad-id");
            if (!std.mem.eql(u8, req.queryParam(.q), "ok")) return Res.text(500, "bad-q");
            if (!std.mem.eql(u8, req.header(.x_token), "token")) return Res.text(500, "bad-header");
            const data = req.middlewareData("auth");
            data.seen = true;
            return rctx.next(req);
        }
    };

    const S = Compiled(void, .{
        get("/u/{id}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                const auth = req.middlewareDataConst(.auth);
                return Res.text(200, if (auth.seen) "ok" else "bad-data");
            }
        }, .{}),
    }, .{Mw});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /u/7?q=ok HTTP/1.1\r\nX-Token: token\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expectEqual(.@"continue", res.action);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\nok"));
}

test "dispatch: pipelined request discards unread content-length body" {
    const S = Compiled(void, .{
        post("/x", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "p");
            }
        }, .{}),
        get("/x", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "g");
            }
        }, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "hello" ++
            "GET /x HTTP/1.1\r\n" ++
            "\r\n",
    );

    const line1 = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out1: [256]u8 = undefined;
    const res1 = try dispatchForTest(S, {}, a, &r, line1, out1[0..]);
    try std.testing.expectEqual(.@"continue", res1.action);
    try std.testing.expect(std.mem.endsWith(u8, out1[0..res1.len], "\r\n\r\np"));

    const line2 = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out2: [256]u8 = undefined;
    const res2 = try dispatchForTest(S, {}, a, &r, line2, out2[0..]);
    try std.testing.expectEqual(.@"continue", res2.action);
    try std.testing.expect(std.mem.endsWith(u8, out2[0..res2.len], "\r\n\r\ng"));
}

test "dispatch: pipelined request discards unread chunked body" {
    const S = Compiled(void, .{
        post("/x", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "p");
            }
        }, .{}),
        get("/x", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "g");
            }
        }, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nhello\r\n0\r\n\r\n" ++
            "GET /x HTTP/1.1\r\n" ++
            "\r\n",
    );

    const line1 = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out1: [256]u8 = undefined;
    const res1 = try dispatchForTest(S, {}, a, &r, line1, out1[0..]);
    try std.testing.expectEqual(.@"continue", res1.action);
    try std.testing.expect(std.mem.endsWith(u8, out1[0..res1.len], "\r\n\r\np"));

    const line2 = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out2: [256]u8 = undefined;
    const res2 = try dispatchForTest(S, {}, a, &r, line2, out2[0..]);
    try std.testing.expectEqual(.@"continue", res2.action);
    try std.testing.expect(std.mem.endsWith(u8, out2[0..res2.len], "\r\n\r\ng"));
}

// Upgrade-specific route tests are intentionally omitted while upgrade support
// is out of the core library.

test "dispatch: path param percent-decodes" {
    const S = Compiled(void, .{
        get("/u/{id}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                return Res.text(200, req.paramValue(.id));
            }
        }, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "GET /u/a%2Fb HTTP/1.1\r\n" ++
            "\r\n",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\na/b"));
}

test "dispatch: named glob captures and percent-decodes" {
    const S = Compiled(void, .{
        get("/g/{*rest}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                return Res.text(200, req.paramValue(.rest));
            }
        }, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "GET /g/a%2Fb/c HTTP/1.1\r\n" ++
            "\r\n",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\na/b/c"));
}

test "dispatch: typed path params via opts.params" {
    const S = Compiled(void, .{
        get("/u/{id}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                const body = try std.fmt.allocPrint(req.allocator(), "{d}", .{req.paramValue(.id)});
                return Res.text(200, body);
            }
        }, .{
            .params = struct {
                id: parse.Int(u32),
            },
        }),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /u/42 HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\n42"));
}

test "dispatch: typed path params bad value errors" {
    const S = Compiled(void, .{
        get("/u/{id}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }, .{
            .params = struct {
                id: parse.Int(u32),
            },
        }),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /u/nope HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    _ = &out;
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    var stream: std.Io.net.Stream = undefined;
    const ServerT = struct {
        /// Stores `io`.
        io: Io,
        /// Stores `ctx`.
        ctx: void,

        /// Implements handle handler error.
        pub fn handleHandlerError(_: *@This(), _: *Io.Writer, comptime _: type, _: anytype) Action {
            unreachable;
        }
    };
    var server: ServerT = .{ .io = std.testing.io, .ctx = {} };
    const rid = S.match(line.method, line.path).?;
    var route_static_ctx: struct {} = .{};
    try std.testing.expectError(error.BadValue, S.dispatch(&server, a, &r, &w, &stream, @ptrCast(&route_static_ctx), line, rid, params[0..S.MaxParams], 8 * 1024));
}

test "dispatch: typed path params with non-string parsers allocate zero" {
    const Alloc = std.mem.Allocator;
    const Alignment = std.mem.Alignment;

    const CountingAllocator = struct {
        /// Stores `inner`.
        inner: Alloc,
        /// Stores `alloc_calls`.
        alloc_calls: usize = 0,
        /// Stores `resize_calls`.
        resize_calls: usize = 0,
        /// Stores `remap_calls`.
        remap_calls: usize = 0,
        /// Stores `free_calls`.
        free_calls: usize = 0,

        fn allocator(self: *@This()) Alloc {
            return .{ .ptr = self, .vtable = &vtable };
        }

        const vtable: Alloc.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.alloc_calls += 1;
            return Alloc.rawAlloc(self.inner, len, alignment, ret_addr);
        }

        fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.resize_calls += 1;
            return Alloc.rawResize(self.inner, memory, alignment, new_len, ret_addr);
        }

        fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.remap_calls += 1;
            return Alloc.rawRemap(self.inner, memory, alignment, new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.free_calls += 1;
            return Alloc.rawFree(self.inner, memory, alignment, ret_addr);
        }
    };

    const S = Compiled(void, .{
        get("/u/{a}/{b}/{c}/{d}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                const sum: u32 = req.paramValue(.a) + req.paramValue(.b) + req.paramValue(.c) + req.paramValue(.d);
                return Res.text(200, if (sum == 10) "ok" else "bad");
            }
        }, .{
            .params = struct {
                a: parse.Int(u32),
                b: parse.Int(u32),
                c: parse.Int(u32),
                d: parse.Int(u32),
            },
        }),
    }, .{});

    var r = Io.Reader.fixed("GET /u/1/2/3/4 HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);

    var backing: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var ca: CountingAllocator = .{ .inner = fba.allocator() };
    const a = ca.allocator();

    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\nok"));
    try std.testing.expectEqual(@as(usize, 0), ca.alloc_calls);
}

test "dispatch: middleware Info.path works" {
    const RequireId = struct {
        pub const Info = @import("middleware.zig").MiddlewareInfo{
            .name = "require_id",
            .path = struct {
                /// Stores `id`.
                id: parse.Int(u32),
            },
        };

        /// Handles a middleware invocation for the current request context.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            if (req.paramValue(.id) == 0) return Res.text(400, "bad");
            return try rctx.next(req);
        }
    };

    const S = Compiled(void, .{
        get("/u/{id}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                const body = try std.fmt.allocPrint(req.allocator(), "{d}", .{req.paramValue(.id)});
                return Res.text(200, body);
            }
        }, .{}),
    }, .{RequireId});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /u/7 HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\n7"));
}

test "middleware data: set in middleware and handler access" {
    const Auth = struct {
        const AuthData = struct { user_id: u32 = 0 };
        pub const Info = @import("middleware.zig").MiddlewareInfo{
            .name = "auth",
            .data = AuthData,
        };

        /// Handles a middleware invocation for the current request context.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            const data = req.middlewareData("auth");
            data.user_id = 7;
            return rctx.next(req);
        }
    };

    const S = Compiled(void, .{
        get("/x", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                const data = req.middlewareData(.auth);
                data.user_id += 1;
                return Res.text(200, if (data.user_id == 8) "ok" else "bad");
            }
        }, .{}),
    }, .{Auth});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /x HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\nok"));
}

test "dispatch: handler error uses callback" {
    const S = Compiled(void, .{
        get("/x", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return error.Boom;
            }
        }, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /x HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    var called = false;
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    var stream: std.Io.net.Stream = undefined;
    const ServerT = struct {
        /// Stores `io`.
        io: Io,
        /// Stores `ctx`.
        ctx: void,
        /// Stores `called`.
        called: *bool,

        /// Implements handle handler error.
        pub fn handleHandlerError(self: *@This(), _: *Io.Writer, comptime _: type, _: anytype) Action {
            self.called.* = true;
            return .close;
        }
    };
    var server: ServerT = .{
        .io = std.testing.io,
        .ctx = {},
        .called = &called,
    };
    const rid = S.match(line.method, line.path).?;
    var route_static_ctx: struct {} = .{};
    const action = try S.dispatch(&server, a, &r, &w, &stream, @ptrCast(&route_static_ctx), line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expect(called);
    try std.testing.expectEqual(.close, action);
    try std.testing.expectEqual(@as(usize, 0), w.end);
}

test "fuzz: router match does not crash" {
    const S = Compiled(void, .{
        get("/a", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "a");
            }
        }, .{}),
        post("/b/{id}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "b");
            }
        }, .{}),
        put("/c/*", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "c");
            }
        }, .{}),
    }, .{});

    const corpus = &.{ "GET", "POST", "HEAD", "BAD" };
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            var params: [S.MaxParams][]u8 = undefined;
            if (params.len != 0) params[0] = @constCast(""[0..0]);
            var method_buf: [8]u8 = undefined;
            var path_buf: [64]u8 = undefined;

            const max_m: u16 = @intCast(method_buf.len);
            const max_p: u16 = @intCast(path_buf.len);
            const mlen_u16 = smith.valueRangeAtMost(u16, 1, max_m);
            const plen_u16 = smith.valueRangeAtMost(u16, 1, max_p);
            const mlen: usize = @intCast(mlen_u16);
            const plen: usize = @intCast(plen_u16);

            smith.bytes(method_buf[0..mlen]);
            smith.bytes(path_buf[0..plen]);
            path_buf[0] = '/';

            _ = S.match(method_buf[0..mlen], path_buf[0..plen]);
        }
    }.testOne, .{ .corpus = corpus });
}

test "endpoint: call can ignore request data" {
    const S = Compiled(void, .{
        get("/a", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "x");
            }
        }, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /a HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\nx"));
}

test "handler: app ctx accessible through req" {
    const Ctx = struct { v: u8 };
    const S = Compiled(Ctx, .{
        get("/a", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                const ctx = req.ctx();
                return Res.text(200, if (ctx.v == 1) "ok" else "bad");
            }
        }, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx: Ctx = .{ .v = 1 };
    var r = Io.Reader.fixed("GET /a HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, &ctx, a, &r, line, out[0..]);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\nok"));
}

test "route: endpoint type accepted" {
    const Endpoint = struct {
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            _ = req;
            return Res.text(200, "ok");
        }
    };

    const S = Compiled(void, .{
        get("/e", Endpoint, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /e HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\nok"));
}

test "dispatch: invalid path percent-encoding rejected" {
    const S = Compiled(void, .{
        get("/u/{id}", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return Res.text(200, "x");
            }
        }, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /u/%ZZ HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    var stream: std.Io.net.Stream = undefined;
    const ServerT = struct {
        /// Stores `io`.
        io: Io,
        /// Stores `ctx`.
        ctx: void,

        /// Implements handle handler error.
        pub fn handleHandlerError(_: *@This(), _: *Io.Writer, comptime _: type, _: anytype) Action {
            unreachable;
        }
    };
    var server: ServerT = .{ .io = std.testing.io, .ctx = {} };
    const rid = S.match(line.method, line.path).?;
    var route_static_ctx: struct {} = .{};
    try std.testing.expectError(error.InvalidPercentEncoding, S.dispatch(&server, a, &r, &w, &stream, @ptrCast(&route_static_ctx), line, rid, params[0..S.MaxParams], 8 * 1024));
}

test "dispatch: route upgrade_handler handles 101 and returns upgraded action" {
    const ServerT = struct {
        /// Stores `io`.
        io: Io,
        /// Stores `ctx`.
        ctx: void,
        /// Stores `upgraded`.
        upgraded: bool,

        /// Implements handle handler error.
        pub fn handleHandlerError(_: *@This(), _: *Io.Writer, comptime _: type, _: anytype) Action {
            unreachable;
        }
    };

    const Routes = struct {
        pub fn call(comptime _: ReqCtx, req: anytype) !Res {
            _ = req;
            return .{
                .status = .switching_protocols,
                .headers = &.{
                    .{ .name = "connection", .value = "Upgrade" },
                    .{ .name = "upgrade", .value = "websocket" },
                },
            };
        }

        fn on_upgrade(server: *ServerT, _: *const std.Io.net.Stream, _: *Io.Reader, _: *Io.Writer, _: request.RequestLine, _: Res) void {
            server.upgraded = true;
        }
    };

    const S = Compiled(void, .{
        get("/ws", Routes, .{ .upgrade_handler = Routes.on_upgrade }),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var server: ServerT = .{
        .io = std.testing.io,
        .ctx = {},
        .upgraded = false,
    };
    var r = Io.Reader.fixed("GET /ws HTTP/1.1\r\nHost: x\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    var stream: std.Io.net.Stream = undefined;
    const rid = S.match(line.method, line.path).?;
    var route_static_ctx: struct {} = .{};
    const action = try S.dispatch(&server, a, &r, &w, &stream, @ptrCast(&route_static_ctx), line, rid, params[0..S.MaxParams], 8 * 1024);

    try std.testing.expectEqual(Action.upgraded, action);
    try std.testing.expect(server.upgraded);
    const expected =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "connection: Upgrade\r\n" ++
        "upgrade: websocket\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected, out[0..w.end]);
}

test "dispatch: null upgrade_handler does not check status" {
    const S = Compiled(void, .{
        get("/ws", struct {
            pub fn call(comptime _: ReqCtx, req: anytype) !Res {
                _ = req;
                return .{
                    .status = .switching_protocols,
                    .headers = &.{
                        .{ .name = "connection", .value = "Upgrade" },
                        .{ .name = "upgrade", .value = "websocket" },
                    },
                };
            }
        }, .{ .upgrade_handler = null }),
    }, .{});

    const ServerT = struct {
        /// Stores `io`.
        io: Io,
        /// Stores `ctx`.
        ctx: void,

        /// Implements handle handler error.
        pub fn handleHandlerError(_: *@This(), _: *Io.Writer, comptime _: type, _: anytype) Action {
            unreachable;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var server: ServerT = .{ .io = std.testing.io, .ctx = {} };
    var r = Io.Reader.fixed("GET /ws HTTP/1.1\r\nHost: x\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    var stream: std.Io.net.Stream = undefined;
    const rid = S.match(line.method, line.path).?;
    var route_static_ctx: struct {} = .{};
    const action = try S.dispatch(&server, a, &r, &w, &stream, @ptrCast(&route_static_ctx), line, rid, params[0..S.MaxParams], 8 * 1024);

    try std.testing.expectEqual(Action.@"continue", action);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "content-length: 0\r\n") != null);
}
