const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Method = @import("server.zig").Method;
const Res = @import("response.zig").Res;
const parse = @import("parse.zig");
const request = @import("request.zig");
const urldecode = @import("urldecode.zig");

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
    comptime method: @EnumLiteral(),
    comptime pattern: []const u8,
    /// Handler function (see supported signatures in `zhttp/root.zig` docs).
    comptime handler: anytype,
    /// Route options (see `zhttp/root.zig` docs). Use `.{}` for none.
    comptime opts: anytype,
) @TypeOf(.{ .method = @as(Method, method), .pattern = pattern, .options = opts, .handler = handler }) {
    validateRouteOptions(opts);
    const m: Method = @as(Method, method);
    return .{
        .method = m,
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

fn tupleLen(comptime t: anytype) usize {
    const info = @typeInfo(@TypeOf(t));
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("expected tuple");
    return info.@"struct".fields.len;
}

fn tupleConcat(
    comptime a: anytype,
    comptime b: anytype,
) std.meta.Tuple(&([_]type{type} ** (tupleLen(a) + tupleLen(b)))) {
    const la: usize = comptime tupleLen(a);
    const lb: usize = comptime tupleLen(b);
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

fn countSegments(comptime pattern: []const u8) usize {
    if (std.mem.eql(u8, pattern, "/")) return 0;
    var c: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '/') c += 1;
    }
    return c; // number of '/' in non-root includes leading '/', so segments = slashes
}

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

fn methodIndex(m: Method) u8 {
    return switch (m) {
        .GET => 0,
        .POST => 1,
        .PUT => 2,
        .DELETE => 3,
        .PATCH => 4,
        .HEAD => 5,
        .OPTIONS => 6,
        .TRACE => 7,
        .CONNECT => 8,
        .OTHER => 9,
    };
}

pub fn Compiled(comptime Context: type, comptime routes: anytype, comptime global_middlewares: anytype) type {
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

    // Build per-method exact maps and pattern lists.
    const tables = comptime blk: {
        var exact_storage: [10][route_count]ExactEntry = undefined;
        var exact_counts: [10]usize = .{0} ** 10;
        var pattern_storage: [10][route_count]u16 = undefined;
        var pattern_counts: [10]usize = .{0} ** 10;

        for (0..10) |mi| {
            var exact_n: usize = 0;
            var pat_n: usize = 0;

            for (route_fields, 0..) |f, i| {
                const rd = @field(routes, f.name);
                if (methodIndex(rd.method) != mi) continue;
                const p = compiled.patterns[i];
                if (p.param_names.len == 0 and !p.glob and std.mem.indexOfScalar(u8, rd.pattern, '{') == null and std.mem.indexOfScalar(u8, rd.pattern, '*') == null) {
                    exact_storage[mi][exact_n] = .{ .path = rd.pattern, .hash = fnv1a64(rd.pattern), .route_index = @intCast(i) };
                    exact_n += 1;
                } else {
                    pattern_storage[mi][pat_n] = @intCast(i);
                    pat_n += 1;
                }
            }

            exact_counts[mi] = exact_n;
            pattern_counts[mi] = pat_n;
        }

        break :blk .{
            .exact_storage = exact_storage,
            .exact_counts = exact_counts,
            .pattern_storage = pattern_storage,
            .pattern_counts = pattern_counts,
        };
    };

    const exact_storage: [10][route_count]ExactEntry = tables.exact_storage;
    const exact_counts: [10]usize = tables.exact_counts;
    const pattern_storage: [10][route_count]u16 = tables.pattern_storage;
    const pattern_counts: [10]usize = tables.pattern_counts;

    const ExactMaps = struct {
        const m0 = ExactMap(exact_storage[0], exact_counts[0]);
        const m1 = ExactMap(exact_storage[1], exact_counts[1]);
        const m2 = ExactMap(exact_storage[2], exact_counts[2]);
        const m3 = ExactMap(exact_storage[3], exact_counts[3]);
        const m4 = ExactMap(exact_storage[4], exact_counts[4]);
        const m5 = ExactMap(exact_storage[5], exact_counts[5]);
        const m6 = ExactMap(exact_storage[6], exact_counts[6]);
        const m7 = ExactMap(exact_storage[7], exact_counts[7]);
        const m8 = ExactMap(exact_storage[8], exact_counts[8]);
        const m9 = ExactMap(exact_storage[9], exact_counts[9]);

        fn find(mi: u8, path: []const u8) ?u16 {
            return switch (mi) {
                0 => m0.find(path),
                1 => m1.find(path),
                2 => m2.find(path),
                3 => m3.find(path),
                4 => m4.find(path),
                5 => m5.find(path),
                6 => m6.find(path),
                7 => m7.find(path),
                8 => m8.find(path),
                9 => m9.find(path),
                else => null,
            };
        }
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

        fn Chain(comptime MwTuple: anytype, comptime handler: anytype, comptime CtxPtr: type, comptime ReqT: type) type {
            const fields = @typeInfo(@TypeOf(MwTuple)).@"struct".fields;
            if (fields.len == 0) {
                return struct {
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
            const NextT = Chain(RestTypes, handler, CtxPtr, ReqT);

            return struct {
                pub fn call(_: @This(), ctx: CtxPtr, reqp: *ReqT) !Res {
                    if (!@hasDecl(First, "call")) @compileError(@typeName(First) ++ " missing `pub fn call(Next, next, ctx, req)`");
                    return First.call(NextT, NextT{}, ctx, reqp);
                }
            };
        }
    };

    const DispatchResult = struct { res: Res, keep_alive: bool };

    const fast_allowed = comptime blk: {
        var out: [route_count]bool = .{false} ** route_count;
        for (route_fields, 0..) |f, i| {
            const rd = @field(routes, f.name);
            const p = compiled.patterns[i];
            const MwTuple = tupleConcat(global_middlewares, optionsField(rd.options, "middlewares", .{}));
            const NeedH = middlewareNeedsHeaders(MwTuple);
            const NeedQ = middlewareNeedsQuery(MwTuple);
            const NeedP = middlewareNeedsParams(MwTuple);
            const H = parse.mergeStructs(NeedH, optionsField(rd.options, "headers", struct {}));
            const Q = parse.mergeStructs(NeedQ, optionsField(rd.options, "query", struct {}));
            const P = parse.mergeStructs(NeedP, optionsField(rd.options, "params", struct {}));

            const h_fields = parse.structFields(H);
            const q_fields = parse.structFields(Q);
            const p_fields = parse.structFields(P);

            // Only exact routes without params/glob and without any capture needs.
            const exact = p.param_names.len == 0 and !p.glob and std.mem.indexOfScalar(u8, rd.pattern, '{') == null and std.mem.indexOfScalar(u8, rd.pattern, '*') == null;
            out[i] = exact and h_fields.len == 0 and q_fields.len == 0 and p_fields.len == 0 and tupleLen(MwTuple) == 0;
        }
        break :blk out;
    };

    return struct {
        pub const RouteCount: usize = route_count;
        pub const MaxParams: usize = compiled.max_params;

        pub fn match(method: Method, path: []u8, params_out: [][]u8) ?u16 {
            const mi = methodIndex(method);
            if (ExactMaps.find(mi, path)) |rid| return rid;

            const n = pattern_counts[mi];
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const rid = pattern_storage[mi][j];
                const p = compiled.patterns[rid];
                if (matchPattern(p, path, params_out)) return rid;
            }

            // HEAD fallback to GET.
            if (method == .HEAD) {
                if (ExactMaps.find(0, path)) |rid| return rid;
                const n2 = pattern_counts[0];
                var k: usize = 0;
                while (k < n2) : (k += 1) {
                    const rid = pattern_storage[0][k];
                    const p = compiled.patterns[rid];
                    if (matchPattern(p, path, params_out)) return rid;
                }
            }
            return null;
        }

        pub fn dispatch(
            ctx: if (Context == void) void else *Context,
            allocator: Allocator,
            r: *Io.Reader,
            line: request.RequestLine,
            route_index: u16,
            params_buf: []const []u8,
            max_header_bytes: usize,
        ) !DispatchResult {
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
                    const ReqT = request.RequestP(H, Q, P, p.param_names);

                    // Copy all path params into a single arena allocation, then percent-decode in place.
                    // We must not keep slices into the Reader's internal buffer, since subsequent reads
                    // (headers/body) may overwrite earlier bytes. Doing this in one allocation avoids
                    // per-param `dupe()` allocations.
                    var params_local: [p.param_names.len][]u8 = undefined;
                    if (p.param_names.len != 0) {
                        var total: usize = 0;
                        inline for (p.param_names, 0..) |_, pidx| total += params_buf[pidx].len;

                        var backing = try allocator.alloc(u8, total);
                        var off: usize = 0;
                        inline for (p.param_names, 0..) |_, pidx| {
                            const raw = params_buf[pidx];
                            @memcpy(backing[off .. off + raw.len], raw);
                            var s = backing[off .. off + raw.len];
                            s = try urldecode.decodeInPlace(s, .path_param);
                            params_local[pidx] = s;
                            off += raw.len;
                        }
                    }

                    var reqv = ReqT.init(allocator, line, params_local[0..]);
                    reqv.reader = r;
                    defer reqv.deinit(allocator);
                    errdefer reqv.discardUnreadBody() catch {};
                    try reqv.parseParams(allocator);
                    try reqv.parseQuery(allocator);
                    try reqv.parseHeaders(allocator, r, max_header_bytes);

                    const CtxPtr = if (Context == void) void else *Context;
                    const ChainT = Dispatch.Chain(MwTuple, rd.handler, CtxPtr, ReqT);
                    const chain = ChainT{};
                    const res = if (Context == void) try chain.call({}, &reqv) else try chain.call(ctx, &reqv);

                    // Ensure unread body is discarded before next request.
                    try reqv.discardUnreadBody();
                    return .{ .res = res, .keep_alive = reqv.keepAlive() };
                }
            }
            return error.BadRequest;
        }

        pub fn dispatchFast(
            ctx: if (Context == void) void else *Context,
            allocator: Allocator,
            r: *Io.Reader,
            line: request.RequestLine,
            route_index: u16,
            params_buf: []const []u8,
            max_header_bytes: usize,
        ) !DispatchResult {
            inline for (route_fields, 0..) |f, i| {
                if (route_index == i and fast_allowed[i]) {
                    const rd = @field(routes, f.name);
                    // Consume headers quickly (unsafe: ignores bodies).
                    try request.discardHeadersOnly(r, max_header_bytes);

                    const empty_line: request.RequestLine = .{
                        .method = line.method,
                        .version = line.version,
                        .path = line.path[0..0],
                        .query = line.query[0..0],
                    };
                    const ReqT = request.Request(struct {}, struct {}, &.{});
                    var reqv = ReqT.init(allocator, empty_line, &.{});
                    defer reqv.deinit(allocator);
                    reqv.reader = r;

                    const res = Dispatch.handlerCall(rd.handler, ctx, &reqv);
                    return .{ .res = try res, .keep_alive = line.version == .http11 };
                }
            }
            return dispatch(ctx, allocator, r, line, route_index, params_buf, max_header_bytes);
        }
    };
}

test "compilePattern glob only at end" {
    _ = compilePattern("/a/*");
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

    var params: [S.MaxParams][]u8 = undefined;

    var p0 = "/a".*;
    try std.testing.expectEqual(@as(?u16, 0), S.match(.GET, p0[0..], params[0..S.MaxParams]));

    var p1 = "/u/123".*;
    try std.testing.expectEqual(@as(?u16, 1), S.match(.GET, p1[0..], params[0..S.MaxParams]));

    var p2 = "/g/anything/here".*;
    try std.testing.expectEqual(@as(?u16, 2), S.match(.GET, p2[0..], params[0..S.MaxParams]));
}

test "router: trailing slash does not match exact literal" {
    const S = Compiled(void, .{
        get("/a", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "a");
            }
        }.h, .{}),
    }, .{});

    var params: [S.MaxParams][]u8 = undefined;
    var p1 = "/a/".*;
    try std.testing.expectEqual(@as(?u16, null), S.match(.GET, p1[0..], params[0..S.MaxParams]));
}

test "router: HEAD falls back to GET handler" {
    const S = Compiled(void, .{
        get("/x", struct {
            fn h(_: void, _: anytype) !Res {
                return Res.text(200, "ok");
            }
        }.h, .{}),
    }, .{});

    var params: [S.MaxParams][]u8 = undefined;
    var p = "/x".*;
    try std.testing.expectEqual(@as(?u16, 0), S.match(.HEAD, p[0..], params[0..S.MaxParams]));
}

test "middleware Needs: supports 'headers: type = ...' form" {
    const Mw = struct {
        pub const Needs = struct {
            headers: type = struct {
                host: parse.Optional(parse.String),
            },
            query: type = struct {},
        };

        pub fn call(comptime Next: type, next: Next, _: void, _: anytype) !Res {
            return next.call({}, undefined);
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

    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "hello" ++
            "GET /x HTTP/1.1\r\n" ++
            "\r\n",
    );

    const line1 = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid1 = S.match(line1.method, line1.path, params[0..S.MaxParams]).?;
    const dr1 = try S.dispatch({}, a, &r, line1, rid1, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqual(@as(u16, 200), dr1.res.status);
    try std.testing.expectEqualStrings("p", dr1.res.body);
    try std.testing.expect(dr1.keep_alive);

    const line2 = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid2 = S.match(line2.method, line2.path, params[0..S.MaxParams]).?;
    const dr2 = try S.dispatch({}, a, &r, line2, rid2, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqual(@as(u16, 200), dr2.res.status);
    try std.testing.expectEqualStrings("g", dr2.res.body);
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

    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nhello\r\n0\r\n\r\n" ++
            "GET /x HTTP/1.1\r\n" ++
            "\r\n",
    );

    const line1 = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid1 = S.match(line1.method, line1.path, params[0..S.MaxParams]).?;
    const dr1 = try S.dispatch({}, a, &r, line1, rid1, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqual(@as(u16, 200), dr1.res.status);
    try std.testing.expectEqualStrings("p", dr1.res.body);
    try std.testing.expect(dr1.keep_alive);

    const line2 = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid2 = S.match(line2.method, line2.path, params[0..S.MaxParams]).?;
    const dr2 = try S.dispatch({}, a, &r, line2, rid2, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqual(@as(u16, 200), dr2.res.status);
    try std.testing.expectEqualStrings("g", dr2.res.body);
}

test "dispatch: path param percent-decodes and dispatchFast falls back" {
    const S = Compiled(void, .{
        get("/u/{id}", struct {
            fn h(_: void, req: anytype) !Res {
                return Res.text(200, req.param(.id));
            }
        }.h, .{}),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed(
        "GET /u/a%2Fb HTTP/1.1\r\n" ++
            "\r\n",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    const dr = try S.dispatch({}, a, &r, line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("a/b", dr.res.body);

    var r2 = Io.Reader.fixed(
        "GET /u/a%2Fb HTTP/1.1\r\n" ++
            "\r\n",
    );
    const line2 = try request.parseRequestLineBorrowed(&r2, 8 * 1024);
    const rid2 = S.match(line2.method, line2.path, params[0..S.MaxParams]).?;
    const dr2 = try S.dispatchFast({}, a, &r2, line2, rid2, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("a/b", dr2.res.body);
}

test "dispatchFast: routes with header needs fall back to full dispatch" {
    const H = struct { host: parse.String };

    const S = Compiled(void, .{
        get("/x", struct {
            fn h(_: void, req: anytype) !Res {
                _ = req.header(.host);
                return Res.text(200, "ok");
            }
        }.h, .{ .headers = H }),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed(
        "GET /x HTTP/1.1\r\n" ++
            "Host: example\r\n" ++
            "\r\n",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    const dr = try S.dispatchFast({}, a, &r, line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("ok", dr.res.body);
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

    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed("GET /u/42 HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    const dr = try S.dispatch({}, a, &r, line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("42", dr.res.body);
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

    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed("GET /u/nope HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    try std.testing.expectError(error.BadValue, S.dispatch({}, a, &r, line, rid, params[0..S.MaxParams], 8 * 1024));
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

    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed("GET /u/1/2/3/4 HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;

    var backing: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);
    var ca: CountingAllocator = .{ .inner = fba.allocator() };
    const a = ca.allocator();

    const dr = try S.dispatch({}, a, &r, line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("ok", dr.res.body);
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

    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed("GET /u/7 HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    const dr = try S.dispatch({}, a, &r, line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("7", dr.res.body);
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

    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed("GET /a HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    const dr = try S.dispatch({}, a, &r, line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("x", dr.res.body);
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
    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed("GET /a HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    const dr = try S.dispatch(&ctx, a, &r, line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("ok", dr.res.body);
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

    var params: [S.MaxParams][]u8 = undefined;
    var r = Io.Reader.fixed("GET /u/%ZZ HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    try std.testing.expectError(error.InvalidPercentEncoding, S.dispatch({}, a, &r, line, rid, params[0..S.MaxParams], 8 * 1024));
}
