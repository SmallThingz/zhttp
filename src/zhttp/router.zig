const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Method = @import("server.zig").Method;
const Res = @import("response.zig").Res;
const parse = @import("parse.zig");
const request = @import("request.zig");
const urldecode = @import("urldecode.zig");

pub fn route(
    comptime method: Method,
    comptime pattern: []const u8,
    comptime opts: anytype,
    comptime handler: anytype,
) @TypeOf(.{ .method = method, .pattern = pattern, .options = opts, .handler = handler }) {
    return .{
        .method = method,
        .pattern = pattern,
        .options = opts,
        .handler = handler,
    };
}

pub fn get(comptime pattern: []const u8, comptime opts: anytype, comptime handler: anytype) @TypeOf(route(.GET, pattern, opts, handler)) {
    return route(.GET, pattern, opts, handler);
}
pub fn post(comptime pattern: []const u8, comptime opts: anytype, comptime handler: anytype) @TypeOf(route(.POST, pattern, opts, handler)) {
    return route(.POST, pattern, opts, handler);
}
pub fn put(comptime pattern: []const u8, comptime opts: anytype, comptime handler: anytype) @TypeOf(route(.PUT, pattern, opts, handler)) {
    return route(.PUT, pattern, opts, handler);
}
pub fn delete(comptime pattern: []const u8, comptime opts: anytype, comptime handler: anytype) @TypeOf(route(.DELETE, pattern, opts, handler)) {
    return route(.DELETE, pattern, opts, handler);
}
pub fn patch(comptime pattern: []const u8, comptime opts: anytype, comptime handler: anytype) @TypeOf(route(.PATCH, pattern, opts, handler)) {
    return route(.PATCH, pattern, opts, handler);
}
pub fn head(comptime pattern: []const u8, comptime opts: anytype, comptime handler: anytype) @TypeOf(route(.HEAD, pattern, opts, handler)) {
    return route(.HEAD, pattern, opts, handler);
}
pub fn options(comptime pattern: []const u8, comptime opts: anytype, comptime handler: anytype) @TypeOf(route(.OPTIONS, pattern, opts, handler)) {
    return route(.OPTIONS, pattern, opts, handler);
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

fn optionsField(comptime opts: anytype, comptime name: []const u8, default: anytype) @TypeOf(default) {
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
            const H = parse.mergeStructs(NeedH, optionsField(rd.options, "headers", struct {}));
            const Q = parse.mergeStructs(NeedQ, optionsField(rd.options, "query", struct {}));

            const h_fields = parse.structFields(H);
            const q_fields = parse.structFields(Q);

            // Only exact routes without params/glob and without any capture needs.
            const exact = p.param_names.len == 0 and !p.glob and std.mem.indexOfScalar(u8, rd.pattern, '{') == null and std.mem.indexOfScalar(u8, rd.pattern, '*') == null;
            out[i] = exact and h_fields.len == 0 and q_fields.len == 0 and tupleLen(MwTuple) == 0;
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
                    const H = parse.mergeStructs(NeedH, optionsField(rd.options, "headers", struct {}));
                    const Q = parse.mergeStructs(NeedQ, optionsField(rd.options, "query", struct {}));
                    const ReqT = request.Request(H, Q, p.param_names);

                var params_local: [p.param_names.len][]u8 = undefined;
                inline for (p.param_names, 0..) |_, pi| {
                    // Duplicate first, then percent-decode in place within the duplicated buffer.
                    // This avoids mutating the borrowed request-line buffer (and avoids leaving
                    // trailing bytes when decoding shrinks the slice).
                    var buf = try allocator.dupe(u8, params_buf[pi]);
                    buf = try urldecode.decodeInPlace(buf, .path_param);
                    params_local[pi] = buf;
                }

                    var reqv = ReqT.init(allocator, line, params_local[0..]);
                    defer reqv.deinit(allocator);
                    errdefer reqv.discardUnreadBody(r) catch {};
                    try reqv.parseQuery(allocator);
                    try reqv.parseHeaders(allocator, r, max_header_bytes);

                    const CtxPtr = if (Context == void) void else *Context;
                    const ChainT = Dispatch.Chain(MwTuple, rd.handler, CtxPtr, ReqT);
                    const chain = ChainT{};
                    const res = if (Context == void) try chain.call({}, &reqv) else try chain.call(ctx, &reqv);

                    // Ensure unread body is discarded before next request.
                    try reqv.discardUnreadBody(r);
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
