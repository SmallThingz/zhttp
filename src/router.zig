const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Res = @import("response.zig").Res;
const parse = @import("parse.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const urldecode = @import("urldecode.zig");
const util = @import("util.zig");

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
/// - `params: type`   Path param captures (parsed from `{name}` segments)
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
                std.mem.eql(u8, name, "middlewares");
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
            }
        }
    }
}

pub fn route(
    /// HTTP method enum literal, e.g. `.GET`.
    comptime method_lit: @EnumLiteral(),
    comptime pattern: []const u8,
    /// Handler function (see supported signatures in `zhttp/root.zig` docs).
    comptime handler: anytype,
    /// Route options (see `zhttp/root.zig` docs). Use `.{}` for none.
    comptime opts: anytype,
) @TypeOf(.{ .method = @tagName(method_lit), .pattern = pattern, .options = opts, .handler = handler }) {
    validateRouteOptions(opts);
    return .{
        .method = @tagName(method_lit),
        .pattern = pattern,
        .options = opts,
        .handler = handler,
    };
}

pub fn get(comptime pattern: []const u8, comptime handler: anytype, comptime opts: anytype) @TypeOf(route(.GET, pattern, handler, opts)) {
    return route(.GET, pattern, handler, opts);
}
pub fn post(comptime pattern: []const u8, comptime handler: anytype, comptime opts: anytype) @TypeOf(route(.POST, pattern, handler, opts)) {
    return route(.POST, pattern, handler, opts);
}
pub fn put(comptime pattern: []const u8, comptime handler: anytype, comptime opts: anytype) @TypeOf(route(.PUT, pattern, handler, opts)) {
    return route(.PUT, pattern, handler, opts);
}
pub fn delete(comptime pattern: []const u8, comptime handler: anytype, comptime opts: anytype) @TypeOf(route(.DELETE, pattern, handler, opts)) {
    return route(.DELETE, pattern, handler, opts);
}
pub fn patch(comptime pattern: []const u8, comptime handler: anytype, comptime opts: anytype) @TypeOf(route(.PATCH, pattern, handler, opts)) {
    return route(.PATCH, pattern, handler, opts);
}
pub fn head(comptime pattern: []const u8, comptime handler: anytype, comptime opts: anytype) @TypeOf(route(.HEAD, pattern, handler, opts)) {
    return route(.HEAD, pattern, handler, opts);
}
pub fn options(comptime pattern: []const u8, comptime handler: anytype, comptime opts: anytype) @TypeOf(route(.OPTIONS, pattern, handler, opts)) {
    return route(.OPTIONS, pattern, handler, opts);
}

fn tupleConcat(
    comptime a: anytype,
    comptime b: anytype,
) std.meta.Tuple(&([_]type{type} ** (util.tupleLen(a) + util.tupleLen(b)))) {
    const la: usize = comptime util.tupleLen(a);
    const lb: usize = comptime util.tupleLen(b);
    const OutFieldTypes = [_]type{type} ** (la + lb);
    const OutT = std.meta.Tuple(&OutFieldTypes);
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

fn tupleTailType(comptime t: anytype) type {
    const fields = @typeInfo(@TypeOf(t)).@"struct".fields;
    if (fields.len <= 1) return @TypeOf(.{});
    const OutFieldTypes = comptime blk: {
        var out: [fields.len - 1]type = undefined;
        for (fields[1..], 0..) |f, i| {
            out[i] = @TypeOf(@field(t, f.name));
        }
        break :blk out;
    };
    return std.meta.Tuple(&OutFieldTypes);
}

fn tupleTail(comptime t: anytype) tupleTailType(t) {
    const fields = @typeInfo(@TypeOf(t)).@"struct".fields;
    if (fields.len <= 1) return .{};
    const OutT = tupleTailType(t);
    return comptime blk: {
        var out: OutT = undefined;
        for (fields[1..], 0..) |f, i| {
            @field(out, std.fmt.comptimePrint("{d}", .{i})) = @field(t, f.name);
        }
        break :blk out;
    };
}

fn middlewareRoutesType(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(50000);
    }
    const info = @typeInfo(@TypeOf(mws));
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("middlewares must be a tuple");
    const fields = info.@"struct".fields;
    if (fields.len == 0) return @TypeOf(.{});

    const First = @field(mws, fields[0].name);
    const Rest = tupleTail(mws);

    const FirstRoutesT = comptime blk: {
        if (!@hasDecl(First, "Routes")) break :blk @TypeOf(.{});
        if (@hasDecl(First, "register_routes") and !First.register_routes) break :blk @TypeOf(.{});
        break :blk @TypeOf(First.Routes);
    };
    const RestRoutesT = middlewareRoutesType(Rest);
    const a: FirstRoutesT = undefined;
    const b: RestRoutesT = undefined;
    return tupleConcatValuesType(a, b);
}

pub fn middlewareRoutes(comptime mws: anytype) middlewareRoutesType(mws) {
    const info = @typeInfo(@TypeOf(mws));
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("middlewares must be a tuple");
    const fields = info.@"struct".fields;
    if (fields.len == 0) return .{};

    const First = @field(mws, fields[0].name);
    const Rest = tupleTail(mws);

    const first_routes = comptime blk: {
        if (!@hasDecl(First, "Routes")) break :blk .{};
        if (@hasDecl(First, "register_routes") and !First.register_routes) break :blk .{};
        break :blk First.Routes;
    };
    const rest_routes = middlewareRoutes(Rest);
    return tupleConcatValues(first_routes, rest_routes);
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

pub fn mergeRoutes(comptime user_routes: anytype, comptime extra_routes: anytype) mergeRoutesType(user_routes, extra_routes) {
    if (util.tupleLen(extra_routes) == 0) return user_routes;
    assertNoDuplicateRoutes(extra_routes);
    assertNoRouteCollisions(user_routes, extra_routes);
    return tupleConcatValues(user_routes, extra_routes);
}

fn optionsField(
    comptime opts: anytype,
    comptime name: []const u8,
    comptime default: anytype,
) @TypeOf(if (@hasField(@TypeOf(opts), name)) @field(opts, name) else default) {
    if (@hasField(@TypeOf(opts), name)) return @field(opts, name);
    return default;
}

fn middlewareNeedsHeaders(comptime mws: anytype) type {
    const fields = @typeInfo(@TypeOf(mws)).@"struct".fields;
    comptime var acc: type = struct {};
    inline for (fields) |f| {
        const Mw = @field(mws, f.name);
        if (@hasDecl(Mw, "Needs")) {
            const NeedsT = Mw.Needs;
            if (@hasDecl(NeedsT, "headers")) {
                acc = parse.mergeStructs(acc, NeedsT.headers);
            } else if (@hasField(NeedsT, "headers")) {
                const needs = NeedsT{};
                acc = parse.mergeStructs(acc, needs.headers);
            }
        }
    }
    return acc;
}

fn middlewareNeedsQuery(comptime mws: anytype) type {
    const fields = @typeInfo(@TypeOf(mws)).@"struct".fields;
    comptime var acc: type = struct {};
    inline for (fields) |f| {
        const Mw = @field(mws, f.name);
        if (@hasDecl(Mw, "Needs")) {
            const NeedsT = Mw.Needs;
            if (@hasDecl(NeedsT, "query")) {
                acc = parse.mergeStructs(acc, NeedsT.query);
            } else if (@hasField(NeedsT, "query")) {
                const needs = NeedsT{};
                acc = parse.mergeStructs(acc, needs.query);
            }
        }
    }
    return acc;
}

fn middlewareNeedsParams(comptime mws: anytype) type {
    const fields = @typeInfo(@TypeOf(mws)).@"struct".fields;
    comptime var acc: type = struct {};
    inline for (fields) |f| {
        const Mw = @field(mws, f.name);
        if (@hasDecl(Mw, "Needs")) {
            const NeedsT = Mw.Needs;
            if (@hasDecl(NeedsT, "params")) {
                acc = parse.mergeStructs(acc, NeedsT.params);
            } else if (@hasField(NeedsT, "params")) {
                const needs = NeedsT{};
                acc = parse.mergeStructs(acc, needs.params);
            }
        }
    }
    return acc;
}

const EmptyMiddlewareData = struct {};

fn middlewareDataType(comptime Mw: type) type {
    if (@hasDecl(Mw, "Data")) return Mw.Data;
    return EmptyMiddlewareData;
}

fn middlewareName(comptime Mw: type) ?[]const u8 {
    if (!@hasDecl(Mw, "Data")) return null;
    const Data = Mw.Data;
    if (@sizeOf(Data) == 0) return null;
    if (!@hasDecl(Mw, "name")) {
        @compileError("middleware " ++ @typeName(Mw) ++ " must declare pub const name when it exposes non-empty Data");
    }

    return switch (@typeInfo(@TypeOf(Mw.name))) {
        .enum_literal => @tagName(Mw.name),
        .pointer => |pointer| if (pointer.child == u8) Mw.name else @compileError("middleware name must be an enum literal or string"),
        .array => |array| if (array.child == u8) Mw.name[0..] else @compileError("middleware name must be an enum literal or string"),
        else => @compileError("middleware name must be an enum literal or string"),
    };
}

fn middlewareHasStoredData(comptime Mw: type) bool {
    return middlewareName(Mw) != null;
}

fn initMiddlewareData(comptime Mw: type) middlewareDataType(Mw) {
    const Data = middlewareDataType(Mw);
    if (Data == EmptyMiddlewareData) return .{};
    if (@hasDecl(Mw, "initData")) {
        return @call(.always_inline, Mw.initData, .{});
    }
    return std.mem.zeroes(Data);
}

fn middlewareContextType(comptime MwTuple: anytype) type {
    const fields = @typeInfo(@TypeOf(MwTuple)).@"struct".fields;
    comptime var field_count: usize = 0;
    inline for (fields) |f| {
        const Mw = @field(MwTuple, f.name);
        const maybe_name = comptime middlewareName(Mw);
        if (maybe_name == null) continue;
        const name = comptime maybe_name.?;
        const Data = middlewareDataType(Mw);

        comptime var seen = false;
        inline for (fields) |pf| {
            if (std.mem.eql(u8, pf.name, f.name)) break;
            const Prev = @field(MwTuple, pf.name);
            const maybe_prev = comptime middlewareName(Prev);
            if (maybe_prev == null) continue;
            const prev_name = comptime maybe_prev.?;
            if (comptime std.mem.eql(u8, prev_name, name)) {
                const PrevData = middlewareDataType(Prev);
                if (PrevData != Data) {
                    @compileError("middleware data field '" ++ name ++ "' has conflicting Data types");
                }
                seen = true;
                break;
            }
        }
        if (!seen) field_count += 1;
    }

    if (field_count == 0) return struct {};

    comptime var out_names: [field_count][]const u8 = undefined;
    comptime var out_types: [field_count]type = undefined;
    comptime var out_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    comptime var out_index: usize = 0;

    inline for (fields) |f| {
        const Mw = @field(MwTuple, f.name);
        const maybe_name = comptime middlewareName(Mw);
        if (maybe_name == null) continue;
        const name = comptime maybe_name.?;
        const Data = middlewareDataType(Mw);

        comptime var seen = false;
        inline for (fields) |pf| {
            if (std.mem.eql(u8, pf.name, f.name)) break;
            const Prev = @field(MwTuple, pf.name);
            const maybe_prev = comptime middlewareName(Prev);
            if (maybe_prev == null) continue;
            const prev_name = comptime maybe_prev.?;
            if (comptime std.mem.eql(u8, prev_name, name)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        out_names[out_index] = name;
        out_types[out_index] = Data;
        out_attrs[out_index] = .{
            .@"comptime" = false,
            .@"align" = @alignOf(Data),
            .default_value_ptr = null,
        };
        out_index += 1;
    }

    return @Struct(.auto, null, out_names[0..], &out_types, &out_attrs);
}

fn initMiddlewareContext(comptime MwTuple: anytype, comptime Ctx: type) Ctx {
    var ctx: Ctx = undefined;
    const fields = @typeInfo(@TypeOf(MwTuple)).@"struct".fields;
    inline for (fields) |f| {
        const Mw = @field(MwTuple, f.name);
        const maybe_name = comptime middlewareName(Mw);
        if (maybe_name == null) continue;
        const name = comptime maybe_name.?;

        comptime var seen = false;
        inline for (fields) |pf| {
            if (std.mem.eql(u8, pf.name, f.name)) break;
            const Prev = @field(MwTuple, pf.name);
            const maybe_prev = comptime middlewareName(Prev);
            if (maybe_prev == null) continue;
            const prev_name = comptime maybe_prev.?;
            if (comptime std.mem.eql(u8, prev_name, name)) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            @field(ctx, name) = initMiddlewareData(Mw);
        }
    }
    return ctx;
}

const SegmentKind = enum { lit, param, glob };
const Segment = struct {
    kind: SegmentKind,
    lit: []const u8 = "",
    param_index: u8 = 0,
};

const Pattern = struct {
    segments: []const Segment,
    param_names: []const []const u8,
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
                if (seg.len < 3) @compileError("param name cannot be empty");
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
                segs[si] = .{ .kind = .param, .param_index = pi };
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
                names[pi] = seg[1 .. seg.len - 1];
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
        if (seg.kind == .glob) {
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
    path: []const u8,
    hash: u64,
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

pub fn Compiled(
    comptime Context: type,
    comptime routes: anytype,
    comptime global_middlewares: anytype,
) type {
    const RoutesType = @TypeOf(routes);
    const routes_info = @typeInfo(RoutesType);
    if (routes_info != .@"struct" or !routes_info.@"struct".is_tuple) @compileError("routes must be a tuple");
    const route_fields = routes_info.@"struct".fields;
    const route_count = route_fields.len;

    const compiled = comptime blk: {
        var patterns: [route_count]Pattern = undefined;
        var max_params: usize = 0;

        for (route_fields, 0..) |f, i| {
            const rd = @field(routes, f.name);
            if (!@hasField(@TypeOf(rd), "method") or !@hasField(@TypeOf(rd), "pattern") or !@hasField(@TypeOf(rd), "handler")) {
                @compileError("route() value must have fields: method, pattern, handler");
            }
            patterns[i] = compilePattern(rd.pattern);
            if (patterns[i].param_names.len > max_params) max_params = patterns[i].param_names.len;
        }

        break :blk .{ .patterns = patterns, .max_params = max_params };
    };

    const method_names = comptime blk: {
        var out: [route_count][]const u8 = undefined;
        var n: usize = 0;
        for (route_fields) |f| {
            const rd = @field(routes, f.name);
            const m = rd.method;
            var found: bool = false;
            for (out[0..n]) |e| {
                if (std.mem.eql(u8, e, m)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                out[n] = m;
                n += 1;
            }
        }
        break :blk .{ .arr = out, .len = n };
    };
    const method_count: usize = method_names.len;

    const route_method_ids: [route_count]u8 = comptime blk: {
        const Methods0 = method_names.arr[0..method_names.len];
        var out: [route_count]u8 = undefined;
        for (route_fields, 0..) |f, i| {
            const rd = @field(routes, f.name);
            var id: ?u8 = null;
            for (Methods0, 0..) |m, mi| {
                if (std.mem.eql(u8, m, rd.method)) {
                    id = @intCast(mi);
                    break;
                }
            }
            out[i] = id orelse @compileError("internal: missing method id");
        }
        break :blk out;
    };

    // Build per-registered-method exact maps and pattern lists.
    const tables = comptime blk: {
        var exact_storage: [method_count][route_count]ExactEntry = undefined;
        var exact_counts: [method_count]usize = .{0} ** method_count;
        var pattern_storage: [method_count][route_count]u16 = undefined;
        var pattern_counts: [method_count]usize = .{0} ** method_count;

        for (0..method_count) |mid| {
            const mid_u8: u8 = @intCast(mid);
            var exact_n: usize = 0;
            var pat_n: usize = 0;

            for (route_fields, 0..) |f, i| {
                if (route_method_ids[i] != mid_u8) continue;
                const rd = @field(routes, f.name);
                const p = compiled.patterns[i];
                const exact = p.param_names.len == 0 and !p.glob and std.mem.indexOfScalar(u8, rd.pattern, '{') == null and std.mem.indexOfScalar(u8, rd.pattern, '*') == null;
                if (exact) {
                    exact_storage[mid][exact_n] = .{ .path = rd.pattern, .hash = fnv1a64(rd.pattern), .route_index = @intCast(i) };
                    exact_n += 1;
                } else {
                    pattern_storage[mid][pat_n] = @intCast(i);
                    pat_n += 1;
                }
            }

            exact_counts[mid] = exact_n;
            pattern_counts[mid] = pat_n;
        }

        break :blk .{
            .exact_storage = exact_storage,
            .exact_counts = exact_counts,
            .pattern_storage = pattern_storage,
            .pattern_counts = pattern_counts,
        };
    };

    const exact_storage: [method_count][route_count]ExactEntry = tables.exact_storage;
    const exact_counts: [method_count]usize = tables.exact_counts;
    const pattern_storage: [method_count][route_count]u16 = tables.pattern_storage;
    const pattern_counts: [method_count]usize = tables.pattern_counts;

    const single_method: []const u8 = if (route_count == 1) @field(routes, route_fields[0].name).method else "";
    const single_pattern: []const u8 = if (route_count == 1) @field(routes, route_fields[0].name).pattern else "";
    const single_exact: bool = route_count == 1 and
        compiled.patterns[0].param_names.len == 0 and
        !compiled.patterns[0].glob and
        std.mem.indexOfScalar(u8, single_pattern, '{') == null and
        std.mem.indexOfScalar(u8, single_pattern, '*') == null;

    const head_id: ?u8 = comptime blk: {
        const Methods0 = method_names.arr[0..method_names.len];
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
        const Methods0 = method_names.arr[0..method_names.len];
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

    const Dispatch = struct {
        fn handlerCall(comptime handler: anytype, ctx: anytype, reqp: anytype) !Res {
            const Ht = @TypeOf(handler);
            const info = @typeInfo(Ht);
            if (info != .@"fn") @compileError("handler must be a function");
            const params = info.@"fn".params;
            if (params.len == 0) return @call(.auto, handler, .{});
            if (params.len == 1) {
                if (@TypeOf(ctx) != void) {
                    if (params[0].type) |pt| {
                        if (pt == @TypeOf(ctx)) return @call(.auto, handler, .{ctx});
                    }
                }
                return @call(.auto, handler, .{reqp});
            }
            if (params.len == 2) return @call(.auto, handler, .{ ctx, reqp });
            @compileError("handler must be fn(), fn(req), fn(ctx), or fn(ctx, req)");
        }

        fn middlewareCallUsesData(comptime Mw: type) bool {
            if (!@hasDecl(Mw, "call")) return false;
            const info = @typeInfo(@TypeOf(Mw.call));
            if (info != .@"fn") @compileError(@typeName(Mw) ++ ".call must be a function");
            const params = info.@"fn".params;
            if (params.len == 5) {
                if (!@hasDecl(Mw, "Data")) {
                    @compileError(@typeName(Mw) ++ ".call takes a data param but middleware has no `pub const Data`");
                }
                const Data = Mw.Data;
                if (params[4].type) |pt| {
                    if (pt == *Data or pt == *const Data) return true;
                    @compileError(@typeName(Mw) ++ ".call data param must be *Data or *const Data");
                }
                @compileError(@typeName(Mw) ++ ".call data param must be *Data or *const Data");
            }
            if (params.len == 4) return false;
            @compileError(@typeName(Mw) ++ ".call must take (Next, next, ctx, req) or (Next, next, ctx, req, data)");
        }

        fn middlewareDataPtr(comptime Mw: type, mw_ctx: anytype) ?*middlewareDataType(Mw) {
            if (!middlewareHasStoredData(Mw)) return null;
            const name = comptime middlewareName(Mw).?;
            return &@field(mw_ctx.*, name);
        }

        fn Chain(comptime MwTuple: anytype, comptime handler: anytype, comptime CtxPtr: type, comptime ReqT: type, comptime MwCtx: type) type {
            comptime {
                @setEvalBranchQuota(50000);
            }
            const fields = @typeInfo(@TypeOf(MwTuple)).@"struct".fields;
            if (fields.len == 0) {
                return struct {
                    mw_ctx: *MwCtx,

                    pub fn call(_: @This(), ctx: CtxPtr, reqp: *ReqT) !Res {
                        return handlerCall(handler, ctx, reqp);
                    }
                };
            }

            const First = @field(MwTuple, fields[0].name);
            const RestTypes = comptime blk: {
                const RestFieldTypes = [_]type{type} ** (fields.len - 1);
                var rest: std.meta.Tuple(&RestFieldTypes) = undefined;
                for (fields[1..], 0..) |f, i| {
                    @field(rest, std.fmt.comptimePrint("{d}", .{i})) = @field(MwTuple, f.name);
                }
                break :blk rest;
            };
            const NextT = Chain(RestTypes, handler, CtxPtr, ReqT, MwCtx);

            return struct {
                mw_ctx: *MwCtx,

                pub fn call(self: @This(), ctx: CtxPtr, reqp: *ReqT) !Res {
                    if (!@hasDecl(First, "call")) @compileError(@typeName(First) ++ " missing `pub fn call(Next, next, ctx, req)`");
                    if (comptime middlewareCallUsesData(First)) {
                        if (middlewareDataPtr(First, self.mw_ctx)) |stored| {
                            return First.call(NextT, NextT{ .mw_ctx = self.mw_ctx }, ctx, reqp, stored);
                        }
                        var empty = initMiddlewareData(First);
                        return First.call(NextT, NextT{ .mw_ctx = self.mw_ctx }, ctx, reqp, &empty);
                    }
                    return First.call(NextT, NextT{ .mw_ctx = self.mw_ctx }, ctx, reqp);
                }
            };
        }
    };

    return struct {
        pub const RouteCount: usize = route_count;
        pub const MaxParams: usize = compiled.max_params;
        pub const RouteParamCounts: [route_count]usize = comptime blk: {
            var out: [route_count]usize = undefined;
            inline for (route_fields, 0..) |_, i| {
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
                const len = method_names.arr[@as(usize, id)].len;
                if (len > m) m = len;
            }
            return m;
        }

        fn uniqueKeys(comptime ids: []const u8, comptime offset: usize) struct { keys: [ids.len]u32, len: usize } {
            var out: [ids.len]u32 = undefined;
            var n: usize = 0;
            for (ids) |id| {
                const k = pack4(method_names.arr[@as(usize, id)], offset);
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
                const k = pack4(method_names.arr[@as(usize, id)], offset);
                if (k == key) {
                    out[n] = id;
                    n += 1;
                }
            }
            return .{ .ids = out, .len = n };
        }

        fn matchMethod(comptime mid: u8, path: []u8) ?u16 {
            const mid_usize: usize = mid;
            const Exact = ExactMap(exact_storage[mid_usize], exact_counts[mid_usize]);
            if (Exact.find(path)) |rid| return rid;

            const n: usize = pattern_counts[mid_usize];
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const rid = pattern_storage[mid_usize][j];
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
                const name: []const u8 = method_names.arr[@as(usize, mid)];
                if (!std.mem.eql(u8, method_token, name)) return null;
                return matchMethod(mid, path);
            }

            if (offset >= comptime maxLenForIds(ids)) {
                inline for (ids) |mid| {
                    const name: []const u8 = method_names.arr[@as(usize, mid)];
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

        pub fn dispatch(
            ctx: if (Context == void) void else *Context,
            io: Io,
            allocator: Allocator,
            r: *Io.Reader,
            w: *Io.Writer,
            line: request.RequestLine,
            route_index: u16,
            params_buf: [][]u8,
            max_header_bytes: usize,
        ) !Action {
            inline for (route_fields, 0..) |f, i| {
                if (route_index == i) {
                    const rd = @field(routes, f.name);
                    const p = compiled.patterns[i];
                    const MwTuple = tupleConcat(global_middlewares, optionsField(rd.options, "middlewares", .{}));
                    const NeedH = middlewareNeedsHeaders(MwTuple);
                    const NeedQ = middlewareNeedsQuery(MwTuple);
                    const NeedP = middlewareNeedsParams(MwTuple);
                    const H = parse.mergeStructs(NeedH, optionsField(rd.options, "headers", struct {}));
                    const Q = parse.mergeStructs(NeedQ, optionsField(rd.options, "query", struct {}));
                    const P = parse.mergeStructs(NeedP, optionsField(rd.options, "params", struct {}));
                    const MwCtx = middlewareContextType(MwTuple);
                    const mw_ctx = initMiddlewareContext(MwTuple, MwCtx);
                    const ReqT = request.RequestPWithPattern(H, Q, P, p.param_names, MwCtx, rd.pattern, rd.method);

                    var params_local: [p.param_names.len][]u8 = undefined;
                    var reqv = ReqT.init(allocator, io, line, mw_ctx);
                    reqv.reader = r;
                    defer reqv.deinit(allocator);
                    errdefer reqv.discardUnreadBody() catch {};
                    if (p.param_names.len != 0) {
                        std.debug.assert(captureParams(route_index, line.path, params_buf));
                    }
                    const params_local_slice: []const []u8 = if (p.param_names.len != 0) params_buf[0..p.param_names.len] else &.{};
                    if (p.param_names.len != 0) {
                        var total: usize = 0;
                        inline for (p.param_names, 0..) |_, pidx| total += params_local_slice[pidx].len;

                        var backing = try allocator.alloc(u8, total);
                        var off: usize = 0;
                        inline for (p.param_names, 0..) |_, pidx| {
                            const raw = params_local_slice[pidx];
                            @memcpy(backing[off .. off + raw.len], raw);
                            var s = backing[off .. off + raw.len];
                            s = try urldecode.decodeInPlace(s, .path_param);
                            params_local[pidx] = s;
                            off += raw.len;
                        }
                    }
                    const decoded_params: []const []u8 = if (p.param_names.len != 0) params_local[0..] else &.{};
                    try reqv.parseParams(allocator, decoded_params);
                    try reqv.parseQuery(allocator);

                    try reqv.parseHeaders(allocator, r, max_header_bytes);

                    const CtxPtr = if (Context == void) void else *Context;
                    const ChainT = Dispatch.Chain(MwTuple, rd.handler, CtxPtr, ReqT, MwCtx);
                    const chain = ChainT{ .mw_ctx = &reqv.mw_ctx };
                    const res = if (Context == void)
                        try chain.call({}, &reqv)
                    else
                        try chain.call(ctx, &reqv);

                    // Ensure unread body is discarded before next request.
                    try reqv.discardUnreadBody();
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
}

fn dispatchForTest(
    comptime S: type,
    ctx: anytype,
    allocator: Allocator,
    r: *Io.Reader,
    line: request.RequestLine,
    out: []u8,
) !struct { action: Action, len: usize } {
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out);
    const rid = S.match(line.method, line.path).?;
    const action = try S.dispatch(ctx, std.testing.io, allocator, r, &w, line, rid, params[0..S.MaxParams], 8 * 1024);
    return .{ .action = action, .len = w.end };
}

test "router: exact + param + glob" {
    const App = struct {};
    const S = Compiled(App, .{
        get("/a", struct {
            fn h(_: *App, _: anytype) !Res {
                return Res.text(200, "a");
            }
        }.h, .{}),
        get("/u/{id}", struct {
            fn h(_: *App, _: anytype) !Res {
                return Res.text(200, "u");
            }
        }.h, .{}),
        get("/g/*", struct {
            fn h(_: *App, _: anytype) !Res {
                return Res.text(200, "g");
            }
        }.h, .{}),
    }, .{});

    var p0 = "/a".*;
    try std.testing.expectEqual(@as(?u16, 0), S.match("GET", p0[0..]));

    var p1 = "/u/123".*;
    try std.testing.expectEqual(@as(?u16, 1), S.match("GET", p1[0..]));

    var p2 = "/g/anything/here".*;
    try std.testing.expectEqual(@as(?u16, 2), S.match("GET", p2[0..]));
}

test "router: trailing slash does not match exact literal" {
    const S = Compiled(void, .{
        get("/a", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "a");
            }
        }.h, .{}),
    }, .{});

    var p1 = "/a/".*;
    try std.testing.expectEqual(@as(?u16, null), S.match("GET", p1[0..]));
}

test "router: HEAD falls back to GET handler" {
    const S = Compiled(void, .{
        get("/x", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "ok");
            }
        }.h, .{}),
    }, .{});

    var p = "/x".*;
    try std.testing.expectEqual(@as(?u16, 0), S.match("HEAD", p[0..]));
}

test "middleware Needs: supports 'headers: type = ...' form" {
    const Mw = struct {
        pub const Needs = struct {
            headers: type = struct {
                host: parse.Optional(parse.String),
            },
            query: type = struct {},
        };

        pub fn call(comptime Next: type, next: Next, _: void, req: anytype) !Res {
            return next.call({}, req);
        }
    };

    _ = Compiled(void, .{
        get("/x", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "x");
            }
        }.h, .{}),
    }, .{Mw});
}

test "dispatch: pipelined request discards unread content-length body" {
    const S = Compiled(void, .{
        post("/x", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "p");
            }
        }.h, .{}),
        get("/x", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "g");
            }
        }.h, .{}),
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
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "p");
            }
        }.h, .{}),
        get("/x", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "g");
            }
        }.h, .{}),
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
            fn h(_: void, req: anytype) !Res {
                return Res.text(200, req.paramValue(.id));
            }
        }.h, .{}),
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

test "dispatch: typed path params via opts.params" {
    const S = Compiled(void, .{
        get("/u/{id}", struct {
            fn h(_: void, req: anytype) !Res {
                const body = try std.fmt.allocPrint(req.allocator(), "{d}", .{req.paramValue(.id)});
                return Res.text(200, body);
            }
        }.h, .{
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
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "ok");
            }
        }.h, .{
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
    const rid = S.match(line.method, line.path).?;
    try std.testing.expectError(error.BadValue, S.dispatch({}, std.testing.io, a, &r, &w, line, rid, params[0..S.MaxParams], 8 * 1024));
}

test "dispatch: path params allocate once" {
    const Alloc = std.mem.Allocator;
    const Alignment = std.mem.Alignment;

    const CountingAllocator = struct {
        inner: Alloc,
        alloc_calls: usize = 0,
        resize_calls: usize = 0,
        remap_calls: usize = 0,
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
            fn h(_: void, req: anytype) !Res {
                const sum: u32 = req.paramValue(.a) + req.paramValue(.b) + req.paramValue(.c) + req.paramValue(.d);
                return Res.text(200, if (sum == 10) "ok" else "bad");
            }
        }.h, .{
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
    try std.testing.expectEqual(@as(usize, 1), ca.alloc_calls);
}

test "dispatch: middleware Needs.params works" {
    const RequireId = struct {
        pub const Needs = struct {
            params: type = struct {
                id: parse.Int(u32),
            },
        };

        pub fn call(comptime Next: type, next: Next, _: void, req: anytype) !Res {
            if (req.paramValue(.id) == 0) return Res.text(400, "bad");
            return try next.call({}, req);
        }
    };

    const S = Compiled(void, .{
        get("/u/{id}", struct {
            fn h(_: void, req: anytype) !Res {
                const body = try std.fmt.allocPrint(req.allocator(), "{d}", .{req.paramValue(.id)});
                return Res.text(200, body);
            }
        }.h, .{}),
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
        pub const Data = struct { user_id: u32 = 0 };
        pub const name = .auth;

        pub fn call(comptime Next: type, next: Next, _: void, req: anytype, data: *Data) !Res {
            data.user_id = 7;
            return next.call({}, req);
        }
    };

    const S = Compiled(void, .{
        get("/x", struct {
            fn h(_: void, req: anytype) !Res {
                const data = req.middlewareData(.auth);
                data.user_id += 1;
                return Res.text(200, if (data.user_id == 8) "ok" else "bad");
            }
        }.h, .{}),
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

test "dispatch: handler error propagates" {
    const S = Compiled(void, .{
        get("/x", struct {
            fn h(_: void, _: anytype) !Res {
                return error.Boom;
            }
        }.h, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /x HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    const rid = S.match(line.method, line.path).?;
    try std.testing.expectError(error.Boom, S.dispatch({}, std.testing.io, a, &r, &w, line, rid, params[0..S.MaxParams], 8 * 1024));
}

test "fuzz: router match does not crash" {
    const S = Compiled(void, .{
        get("/a", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "a");
            }
        }.h, .{}),
        post("/b/{id}", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "b");
            }
        }.h, .{}),
        put("/c/*", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "c");
            }
        }.h, .{}),
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

test "handler: zero-arg handler supported" {
    const S = Compiled(void, .{
        get("/a", struct {
            fn h() !Res {
                return Res.text(200, "x");
            }
        }.h, .{}),
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

test "handler: ctx-only handler supported" {
    const Ctx = struct { v: u8 };
    const S = Compiled(Ctx, .{
        get("/a", struct {
            fn h(ctx: *Ctx) !Res {
                return Res.text(200, if (ctx.v == 1) "ok" else "bad");
            }
        }.h, .{}),
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

test "dispatch: invalid path percent-encoding rejected" {
    const S = Compiled(void, .{
        get("/u/{id}", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "x");
            }
        }.h, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /u/%ZZ HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    const rid = S.match(line.method, line.path).?;
    try std.testing.expectError(error.InvalidPercentEncoding, S.dispatch({}, std.testing.io, a, &r, &w, line, rid, params[0..S.MaxParams], 8 * 1024));
}
