const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Res = @import("response.zig").Res;
const parse = @import("parse.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const urldecode = @import("urldecode.zig");
const middleware = @import("middleware.zig");
const req_ctx = @import("req_ctx.zig");
const route_decl = @import("route_decl.zig");
const util = @import("util.zig");
const ReqCtx = req_ctx.ReqCtx;

comptime {
    @setEvalBranchQuota(2_000_000);
}

pub const Action = enum {
    @"continue",
    close,
    upgraded,
};

pub const EndpointInfo = route_decl.EndpointInfo;
pub const RouteDecl = route_decl.RouteDecl;

fn validateStructTypeOpt(comptime field_name: []const u8, comptime maybe_t: ?type) void {
    if (maybe_t) |T| {
        if (@typeInfo(T) != .@"struct") {
            @compileError("endpoint Info." ++ field_name ++ " must be a struct type");
        }
    }
}

fn validateEndpointInfo(comptime endpoint: type) EndpointInfo {
    if (!@hasDecl(endpoint, "Info")) {
        @compileError("route endpoint type must expose `pub const Info: router.EndpointInfo = .{ ... };`");
    }
    if (@TypeOf(endpoint.Info) != EndpointInfo) {
        @compileError("route endpoint Info must be of type router.EndpointInfo");
    }
    const info: EndpointInfo = endpoint.Info;
    validateStructTypeOpt("headers", info.headers);
    validateStructTypeOpt("query", info.query);
    validateStructTypeOpt("path", info.path);
    return info;
}

fn endpointType(comptime endpoint: type) struct { endpoint: type, info: EndpointInfo } {
    if (!@hasDecl(endpoint, "call")) {
        @compileError("route endpoint type must expose `pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response(Body)`");
    }
    return .{
        .endpoint = endpoint,
        .info = validateEndpointInfo(endpoint),
    };
}

pub fn route(
    /// HTTP method enum literal, e.g. `.GET`.
    comptime method_lit: @EnumLiteral(),
    comptime pattern: []const u8,
    /// Route endpoint type exposing `pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response(Body)`.
    comptime endpoint: type,
) RouteDecl {
    const ep = endpointType(endpoint);
    return .{
        .method = @tagName(method_lit),
        .pattern = pattern,
        .endpoint = ep.endpoint,
        .headers = ep.info.headers orelse struct {},
        .query = ep.info.query orelse struct {},
        .params = ep.info.path orelse struct {},
        .middlewares = ep.info.middlewares,
        .operations = ep.info.operations,
    };
}

pub fn get(comptime pattern: []const u8, comptime endpoint: type) RouteDecl {
    return route(.GET, pattern, endpoint);
}
pub fn post(comptime pattern: []const u8, comptime endpoint: type) RouteDecl {
    return route(.POST, pattern, endpoint);
}
pub fn put(comptime pattern: []const u8, comptime endpoint: type) RouteDecl {
    return route(.PUT, pattern, endpoint);
}
pub fn delete(comptime pattern: []const u8, comptime endpoint: type) RouteDecl {
    return route(.DELETE, pattern, endpoint);
}
pub fn patch(comptime pattern: []const u8, comptime endpoint: type) RouteDecl {
    return route(.PATCH, pattern, endpoint);
}
pub fn head(comptime pattern: []const u8, comptime endpoint: type) RouteDecl {
    return route(.HEAD, pattern, endpoint);
}
pub fn options(comptime pattern: []const u8, comptime endpoint: type) RouteDecl {
    return route(.OPTIONS, pattern, endpoint);
}

/// Convert a capture struct into the `ReqCtx.ST` name/type format consumed by
/// generated request contexts.
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
    kind: SegmentKind,
    lit: []const u8 = "",
    param_index: u8 = 0,
};

const Pattern = struct {
    segments: []const Segment,
    param_names: []const []const u8,
    glob: bool,
};

/// Compile a route pattern into fixed segment metadata so runtime matching can
/// stay allocation-free.
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

/// Match a path and capture parameter slices directly from the request path.
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

/// Boolean-only variant of `matchPattern` for paths that do not need captures.
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

const ExactEntry = struct {
    path: []const u8,
    hash: u64,
    route_index: u16,
};

/// Build a comptime open-addressing table for exact path matches.
fn ExactMap(comptime entries: anytype, comptime n: usize) type {
    const EntriesT = @TypeOf(entries);
    comptime {
        const info = @typeInfo(EntriesT);
        if (info != .array or info.array.child != ExactEntry) {
            @compileError("ExactMap entries must be an array of ExactEntry");
        }
    }

    const cap: usize = util.nextPow2AtLeast(n * 2 + 1, 8);
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
        /// Find the route index for an exact path match.
        pub fn find(path: []const u8) ?u16 {
            if (n == 0) return null;
            const h = util.fnv1a64(path);
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

fn PatternRadix(comptime all_patterns: []const Pattern, comptime route_ids: []const u16) type {
    if (route_ids.len == 0) {
        return struct {
            pub fn match(_: []u8) ?u16 {
                return null;
            }
        };
    }

    const max_segments = comptime blk: {
        var m: usize = 1;
        for (route_ids) |rid| {
            const segs = all_patterns[rid].segments.len;
            if (segs > m) m = segs;
        }
        break :blk m;
    };
    const max_nodes = route_ids.len * max_segments + 1;
    const max_lits = route_ids.len * max_segments;
    const max_params = max_lits;
    // Worst-case slot footprint is sparse nodes where each literal group has one entry.
    // In that case each group gets the minimum table size (8).
    const max_slots = max_lits * 8 + 8;

    const TempLitEdge = struct {
        lit: []const u8 = "",
        child: u16 = 0,
        next: ?u16 = null,
    };
    const TempNode = struct {
        end_route: u16 = 0,
        glob_route: u16 = 0,
        param_child: ?u16 = null,
        lit_head: ?u16 = null,
    };
    const ParamBranch = struct {
        count: u8 = 0,
        next_node: ?u16 = null,
        end_route: u16 = 0,
        glob_route: u16 = 0,
    };
    const LitEntry = struct {
        key: []const u8 = "",
        hash: u64 = 0,
        child: u16 = 0,
    };
    const Node = struct {
        end_route: u16 = 0,
        glob_route: u16 = 0,
        param_start: u16 = 0,
        param_len: u16 = 0,
        lit_frag_count: u8 = 0,
        lit_start: u16 = 0,
        lit_len: u16 = 0,
        lit_slot_start: u16 = 0,
        lit_slot_cap: u16 = 0,
        first_byte_mask: [4]u64 = .{0} ** 4,
    };

    const Built = struct {
        nodes: [max_nodes]Node,
        lits: [max_lits]LitEntry,
        params: [max_params]ParamBranch,
        lit_slots: [max_slots]u16,
    };

    const Builder = struct {
        temp_nodes: [max_nodes]TempNode = [_]TempNode{.{}} ** max_nodes,
        temp_lits: [max_lits]TempLitEdge = [_]TempLitEdge{.{}} ** max_lits,
        temp_node_count: usize = 1,
        temp_lit_count: usize = 0,

        out_nodes: [max_nodes]Node = [_]Node{.{}} ** max_nodes,
        out_lits: [max_lits]LitEntry = [_]LitEntry{.{}} ** max_lits,
        out_params: [max_params]ParamBranch = [_]ParamBranch{.{}} ** max_params,
        out_slots: [max_slots]u16 = .{0} ** max_slots,
        out_node_count: usize = 0,
        out_lit_count: usize = 0,
        out_param_count: usize = 0,
        out_slot_count: usize = 0,
        temp_to_out: [max_nodes]u16 = .{0} ** max_nodes, // stores index+1

        fn setMinRoute(slot: *u16, value: u16) void {
            if (slot.* == 0 or value < slot.*) slot.* = value;
        }

        /// Allocates a new transient trie node during route-shape ingestion.
        fn newTempNode(self: *@This()) u16 {
            if (self.temp_node_count >= max_nodes) @compileError("PatternRadix temp node overflow");
            const idx: u16 = @intCast(self.temp_node_count);
            self.temp_node_count += 1;
            return idx;
        }

        /// Adds a literal edge in the temporary adjacency list.
        fn addTempLitEdge(self: *@This(), lit: []const u8, child: u16, next: ?u16) u16 {
            if (self.temp_lit_count >= max_lits) @compileError("PatternRadix temp lit overflow");
            const idx: u16 = @intCast(self.temp_lit_count);
            self.temp_lit_count += 1;
            self.temp_lits[idx] = .{
                .lit = lit,
                .child = child,
                .next = next,
            };
            return idx;
        }

        /// Looks up an existing literal branch so identical literals share nodes.
        fn findTempLitChild(self: *@This(), node_idx: u16, lit: []const u8) ?u16 {
            var edge_idx = self.temp_nodes[node_idx].lit_head;
            while (edge_idx) |eidx| : (edge_idx = self.temp_lits[eidx].next) {
                const edge = self.temp_lits[eidx];
                if (std.mem.eql(u8, edge.lit, lit)) return edge.child;
            }
            return null;
        }

        /// Inserts one compiled route pattern into the temporary trie form.
        fn insertPattern(self: *@This(), pattern: Pattern, route_index: u16) void {
            const route_id = route_index + 1;
            var node_idx: u16 = 0;
            for (pattern.segments) |seg| {
                switch (seg.kind) {
                    .lit => {
                        if (self.findTempLitChild(node_idx, seg.lit)) |child_idx| {
                            node_idx = child_idx;
                        } else {
                            const child_idx = self.newTempNode();
                            const lit_head = self.temp_nodes[node_idx].lit_head;
                            const edge_idx = self.addTempLitEdge(seg.lit, child_idx, lit_head);
                            self.temp_nodes[node_idx].lit_head = edge_idx;
                            node_idx = child_idx;
                        }
                    },
                    .param => {
                        if (self.temp_nodes[node_idx].param_child) |child_idx| {
                            node_idx = child_idx;
                        } else {
                            const child_idx = self.newTempNode();
                            self.temp_nodes[node_idx].param_child = child_idx;
                            node_idx = child_idx;
                        }
                    },
                    .glob, .glob_param => {
                        setMinRoute(&self.temp_nodes[node_idx].glob_route, route_id);
                        return;
                    },
                }
            }
            setMinRoute(&self.temp_nodes[node_idx].end_route, route_id);
        }

        fn tempLitCount(self: *@This(), node_idx: u16) usize {
            var c: usize = 0;
            var edge_idx = self.temp_nodes[node_idx].lit_head;
            while (edge_idx) |eidx| : (edge_idx = self.temp_lits[eidx].next) c += 1;
            return c;
        }

        /// Returns how many literal fragments can be radix-compressed together.
        fn edgeCompressionLen(self: *@This(), start_child: u16) u8 {
            var count: u8 = 1;
            var cur = start_child;
            while (true) {
                const node = self.temp_nodes[cur];
                if (node.end_route != 0 or node.glob_route != 0 or node.param_child != null) break;
                const lit_head = node.lit_head orelse break;
                if (self.temp_lits[lit_head].next != null) break;
                count += 1;
                cur = self.temp_lits[lit_head].child;
            }
            return count;
        }

        /// Concatenates `frag_count` literal fragments (`a/b/c`) into one map key.
        fn buildCompressedKey(self: *@This(), first_lit: []const u8, first_child: u16, frag_count: u8) struct { key: []const u8, next_temp_idx: u16 } {
            var key: []const u8 = first_lit;
            var cur = first_child;
            var rem = frag_count;
            rem -= 1;
            while (rem != 0) : (rem -= 1) {
                const lit_head = self.temp_nodes[cur].lit_head.?;
                const edge = self.temp_lits[lit_head];
                key = key ++ "/" ++ edge.lit;
                cur = edge.child;
            }
            return .{
                .key = key,
                .next_temp_idx = cur,
            };
        }

        /// Lowers one temporary trie node into the compact runtime lookup layout.
        fn compileNode(self: *@This(), temp_idx: u16) u16 {
            if (self.temp_to_out[temp_idx] != 0) return self.temp_to_out[temp_idx] - 1;
            if (self.out_node_count >= max_nodes) @compileError("PatternRadix node overflow");
            const out_idx: u16 = @intCast(self.out_node_count);
            self.out_node_count += 1;
            self.temp_to_out[temp_idx] = out_idx + 1;

            const tnode = self.temp_nodes[temp_idx];
            self.out_nodes[out_idx].end_route = tnode.end_route;
            self.out_nodes[out_idx].glob_route = tnode.glob_route;

            if (tnode.param_child) |param_start| {
                const param_start_idx: u16 = @intCast(self.out_param_count);
                var count: u8 = 1;
                var walk_idx = param_start;
                while (true) {
                    const walk = self.temp_nodes[walk_idx];
                    if (walk.end_route != 0 or walk.glob_route != 0 or walk.lit_head != null) {
                        if (self.out_param_count >= max_params) @compileError("PatternRadix param overflow");
                        var branch: ParamBranch = .{
                            .count = count,
                            .end_route = walk.end_route,
                            .glob_route = walk.glob_route,
                        };
                        if (walk.lit_head != null or walk.param_child != null) {
                            branch.next_node = self.compileNode(walk_idx);
                        }
                        self.out_params[self.out_param_count] = branch;
                        self.out_param_count += 1;
                    }
                    if (walk.param_child) |next_param| {
                        count += 1;
                        walk_idx = next_param;
                        continue;
                    }
                    break;
                }
                self.out_nodes[out_idx].param_start = param_start_idx;
                self.out_nodes[out_idx].param_len = @intCast(self.out_param_count - param_start_idx);
            }

            const lit_count = self.tempLitCount(temp_idx);
            if (lit_count != 0) {
                var frag_count: u8 = std.math.maxInt(u8);
                var edge_idx = tnode.lit_head;
                while (edge_idx) |eidx| : (edge_idx = self.temp_lits[eidx].next) {
                    const ec = self.edgeCompressionLen(self.temp_lits[eidx].child);
                    if (ec < frag_count) frag_count = ec;
                }
                self.out_nodes[out_idx].lit_frag_count = frag_count;
                const lit_start_idx: u16 = @intCast(self.out_lit_count);
                self.out_nodes[out_idx].lit_start = lit_start_idx;

                edge_idx = tnode.lit_head;
                while (edge_idx) |eidx| : (edge_idx = self.temp_lits[eidx].next) {
                    if (self.out_lit_count >= max_lits) @compileError("PatternRadix lit overflow");
                    const edge = self.temp_lits[eidx];
                    const built_key = self.buildCompressedKey(edge.lit, edge.child, frag_count);
                    const child_idx = self.compileNode(built_key.next_temp_idx);
                    self.out_lits[self.out_lit_count] = .{
                        .key = built_key.key,
                        .hash = util.fnv1a64(built_key.key),
                        .child = child_idx,
                    };
                    const b0 = built_key.key[0];
                    const bucket_i: usize = b0 >> 6;
                    self.out_nodes[out_idx].first_byte_mask[bucket_i] |= @as(u64, 1) << @intCast(b0 & 63);
                    self.out_lit_count += 1;
                }

                const lit_len: u16 = @intCast(self.out_lit_count - lit_start_idx);
                self.out_nodes[out_idx].lit_len = lit_len;
                const cap = util.nextPow2AtLeast(lit_len * 2 + 1, 8);
                if (self.out_slot_count + cap > max_slots) @compileError("PatternRadix slot overflow");
                const slot_start: u16 = @intCast(self.out_slot_count);
                self.out_nodes[out_idx].lit_slot_start = slot_start;
                self.out_nodes[out_idx].lit_slot_cap = @intCast(cap);
                var i: usize = 0;
                while (i < cap) : (i += 1) self.out_slots[self.out_slot_count + i] = 0;
                self.out_slot_count += cap;

                var li: usize = lit_start_idx;
                while (li < self.out_lit_count) : (li += 1) {
                    const lit = self.out_lits[li];
                    const mask: u64 = cap - 1;
                    var pos: u64 = lit.hash & mask;
                    while (true) : (pos = (pos + 1) & mask) {
                        const slot_i = @as(usize, slot_start) + @as(usize, @intCast(pos));
                        if (self.out_slots[slot_i] == 0) {
                            self.out_slots[slot_i] = @intCast(li + 1);
                            break;
                        }
                    }
                }
            }

            return out_idx;
        }

        /// Finalizes builder storage into immutable compile-time tables.
        fn finish(self: *@This()) Built {
            return .{
                .nodes = self.out_nodes,
                .lits = self.out_lits,
                .params = self.out_params,
                .lit_slots = self.out_slots,
            };
        }
    };

    const built = comptime blk: {
        var b = Builder{};
        for (route_ids) |rid| {
            b.insertPattern(all_patterns[rid], rid);
        }
        _ = b.compileNode(0);
        break :blk b.finish();
    };

    const Self = struct {
        /// Parses one non-empty raw path segment and returns the next cursor.
        fn parseRawSeg(path: []const u8, pos: usize) ?usize {
            if (pos > path.len) return null;
            const slash = std.mem.indexOfScalarPos(u8, path, pos, '/') orelse path.len;
            const seg = path[pos..slash];
            if (seg.len == 0) return null;
            return if (slash == path.len) path.len + 1 else slash + 1;
        }

        /// Advances by `count` raw segments without decoding/capturing.
        fn skipRawSegs(path: []const u8, pos: usize, count: u8) ?usize {
            var cur = pos;
            var rem = count;
            while (rem != 0) : (rem -= 1) {
                cur = parseRawSeg(path, cur) orelse return null;
            }
            return cur;
        }

        /// Slices a radix-compressed literal group key from the incoming path.
        fn consumeLiteralGroup(path: []const u8, pos: usize, frag_count: u8) ?struct { key: []const u8, next_pos: usize } {
            if (frag_count == 0) return null;
            var cur = pos;
            var rem = frag_count;
            while (rem != 0) : (rem -= 1) {
                cur = parseRawSeg(path, cur) orelse return null;
            }
            const end = if (cur == path.len + 1) path.len else cur - 1;
            return .{
                .key = path[pos..end],
                .next_pos = cur,
            };
        }

        /// Resolves a literal child via the node's open-addressing hash table.
        fn findLiteral(node: Node, key: []const u8) ?u16 {
            if (node.lit_len == 0) return null;
            const b0 = key[0];
            const bmask_i: usize = b0 >> 6;
            if ((node.first_byte_mask[bmask_i] & (@as(u64, 1) << @intCast(b0 & 63))) == 0) return null;
            if (node.lit_slot_cap == 0) return null;

            const hash = util.fnv1a64(key);
            const cap: usize = node.lit_slot_cap;
            const mask: u64 = cap - 1;
            var pos: u64 = hash & mask;
            var probe: usize = 0;
            while (probe < cap) : (probe += 1) {
                const slot_i = @as(usize, node.lit_slot_start) + @as(usize, @intCast(pos));
                const slot = built.lit_slots[slot_i];
                if (slot == 0) return null;
                const lit = built.lits[slot - 1];
                if (lit.hash == hash and lit.key.len == key.len and std.mem.eql(u8, lit.key, key)) return lit.child;
                pos = (pos + 1) & mask;
            }
            return null;
        }

        /// Recursive matcher that enforces literal > param-chain > glob precedence.
        fn matchNode(path: []const u8, pos: usize, node_idx: u16) u16 {
            const node = built.nodes[node_idx];
            if (pos == path.len + 1) {
                if (node.end_route != 0) return node.end_route;
                return node.glob_route;
            }

            if (node.lit_frag_count != 0) {
                if (consumeLiteralGroup(path, pos, node.lit_frag_count)) |group| {
                    if (findLiteral(node, group.key)) |child_idx| {
                        const m = matchNode(path, group.next_pos, child_idx);
                        if (m != 0) return m;
                    }
                }
            }

            var last_eligible: isize = -1;
            var i: usize = node.param_start;
            const pend: usize = node.param_start + node.param_len;
            while (i < pend) : (i += 1) {
                const branch = built.params[i];
                const next_pos = skipRawSegs(path, pos, branch.count) orelse break;
                last_eligible = @intCast(i);

                if (branch.next_node) |next_node| {
                    const m = matchNode(path, next_pos, next_node);
                    if (m != 0) return m;
                }
                if (branch.end_route != 0 and next_pos == path.len + 1) return branch.end_route;
            }

            var j = last_eligible;
            while (j >= @as(isize, @intCast(node.param_start))) : (j -= 1) {
                const branch = built.params[@intCast(j)];
                if (branch.glob_route != 0) return branch.glob_route;
            }
            return node.glob_route;
        }

        pub fn match(path: []u8) ?u16 {
            if (path.len == 0 or path[0] != '/') return null;
            const start_pos = if (path.len == 1) path.len + 1 else 1;
            const route_id = matchNode(path, start_pos, 0);
            return if (route_id == 0) null else route_id - 1;
        }
    };

    return Self;
}

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
                            .hash = util.fnv1a64(rd.pattern),
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
        pub const RouteDeclList: [route_count]RouteDecl = blk: {
            var out: [route_count]RouteDecl = undefined;
            for (route_fields, 0..) |f, i| {
                out[i] = @field(routes, f.name);
            }
            break :blk out;
        };
        pub const MaxParams: usize = compiled.max_params;
        pub const DispatchError = error{
            EndOfStream,
            ReadFailed,
            WriteFailed,
            HeadersTooLarge,
            PayloadTooLarge,
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
            const PatternMatcher = PatternRadix(
                compiled.patterns[0..],
                compiled.pattern_storage[mid_usize][0..compiled.pattern_counts[mid_usize]],
            );
            return PatternMatcher.match(path);
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
            // Build a decision tree over 4-byte chunks of method names so the
            // multi-method case avoids a purely linear string-compare chain.
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

        /// Re-run the compiled matcher for a known route index and fill the
        /// per-route params buffer.
        fn captureParams(route_index: u16, path: []u8, params_out: [][]u8) bool {
            inline for (route_fields, 0..) |_, i| {
                if (route_index == i) {
                    return matchPattern(compiled.patterns[i], path, params_out);
                }
            }
            return false;
        }

        /// Serializes and flushes a response and returns the next connection action.
        fn finishResponse(
            comptime rctx: ReqCtx,
            req_ro: rctx.TReadOnly(),
            w: *Io.Writer,
            res: anytype,
            keep_alive: bool,
            send_body: bool,
        ) !Action {
            // Response formatting is centralized here so the dispatch path can
            // return only transport actions while body serialization stays
            // close to the final writer.
            try response.writeAny(rctx, req_ro, w, res, keep_alive, send_body);
            if (w.buffered().len != 0) {
                try w.flush();
            }
            return if (!keep_alive or res.close) .close else .@"continue";
        }

        /// Invokes endpoint-defined upgrade callback after a successful 101 write.
        fn callUpgradeHandler(
            comptime Endpoint: type,
            server: anytype,
            stream: *const std.Io.net.Stream,
            r: *Io.Reader,
            w: *Io.Writer,
            line: request.RequestLine,
            res: anytype,
        ) void {
            const handler = Endpoint.upgrade;
            const HandlerT = @TypeOf(handler);
            const h_info = @typeInfo(HandlerT);
            if (h_info != .@"fn") @compileError("endpoint upgrade must be a function");
            if (h_info.@"fn".return_type != void) @compileError("endpoint upgrade must return void");
            if (h_info.@"fn".params.len != 6) {
                @compileError("endpoint upgrade must be fn(server, stream, r, w, line, res) void");
            }
            @call(.auto, handler, .{ server, stream, r, w, line, res });
        }

        /// Handles `101 Switching Protocols` when an endpoint exposes `upgrade`.
        fn maybeHandleUpgradeEntry(
            comptime Endpoint: type,
            server: anytype,
            stream: *const std.Io.net.Stream,
            r: *Io.Reader,
            w: *Io.Writer,
            line: request.RequestLine,
            res: anytype,
        ) DispatchError!?Action {
            if (!@hasDecl(Endpoint, "upgrade")) return null;
            if (res.status != .switching_protocols) return null;
            try response.writeUpgrade(w, res);
            if (w.buffered().len != 0) try w.flush();
            // After `101`, protocol handlers should not inherit the HTTP
            // response buffer because websocket control frames must be
            // write-visible immediately.
            var upgrade_write_buf: [0]u8 = undefined;
            var upgrade_w = stream.writer(server.io, &upgrade_write_buf);
            callUpgradeHandler(Endpoint, server, stream, r, &upgrade_w.interface, line, res);
            return .upgraded;
        }

        pub fn dispatch(
            server: anytype,
            allocator: Allocator,
            r: *Io.Reader,
            w: *Io.Writer,
            stream: *const std.Io.net.Stream,
            line: request.RequestLine,
            route_index: u16,
            params_buf: [][]u8,
            max_header_bytes: usize,
            max_single_header_bytes: usize,
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
                    const req_rd: route_decl.RouteDecl = .{
                        .method = rd.method,
                        .pattern = rd.pattern,
                        .endpoint = rd.endpoint,
                        .headers = H,
                        .query = Q,
                        .params = P,
                        .middlewares = rd.middlewares,
                        .operations = rd.operations,
                    };
                    const ReqT = request.RequestPWithPatternExt(@TypeOf(server), i, req_rd, MwCtx);
                    const EndpointHandler = struct {
                        pub const function = rd.endpoint.call;
                    };
                    const ReqCtxT = req_ctx.ReqCtx;
                    const rctx: ReqCtxT = comptime .{
                        .handler = EndpointHandler,
                        .middlewares = MwList,
                        .path = structFieldsToST(P),
                        .query = structFieldsToST(Q),
                        .headers = structFieldsToST(H),
                        .middleware_contexts = middleware.contextST(MwList),
                        .idx = 0,
                        ._base_req_type = ReqT,
                        ._server_type = @TypeOf(server.*),
                    };
                    var reqv = ReqT.initWithServer(allocator, line, mw_ctx, server);
                    reqv.base().reader = r;
                    reqv.base().writer = w;
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

                    try reqv.parseHeadersWithLimits(allocator, r, max_header_bytes, max_single_header_bytes);

                    const req0: rctx.T() = .{
                        ._base = &reqv,
                        .path = line.path,
                        .method = line.method,
                    };
                    const tail_rctx = comptime rctx.withIdx(MwList.len);
                    const req_tail: tail_rctx.T() = .{
                        ._base = &reqv,
                        .path = line.path,
                        .method = line.method,
                    };
                    const req_ro: rctx.TReadOnly() = .{
                        ._base = &reqv,
                        .path = line.path,
                        .method = line.method,
                    };
                    const res = rctx.run(req0) catch |err| {
                        req_tail.discardUnreadBody() catch return .close;
                        const ServerT = @TypeOf(server.*);
                        const action = ServerT.handleHandlerError(server, w, @TypeOf(err), err);
                        if (action != .upgraded) {
                            w.flush() catch return .close;
                        }
                        return action;
                    };

                    // Ensure unread body is discarded before next request.
                    try req_tail.discardUnreadBody();
                    if (try maybeHandleUpgradeEntry(rd.endpoint, server, stream, r, w, line, res)) |act| return act;
                    const send_body = !(line.method.len == 4 and line.method[0] == 'H' and line.method[1] == 'E' and line.method[2] == 'A' and line.method[3] == 'D');
                    return finishResponse(rctx, req_ro, w, res, reqv.keepAlive(), send_body);
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

fn TestServer(comptime CtxT: type) type {
    return struct {
        const RouteStaticCtx = struct {};
        io: Io,
        gpa: Allocator,
        ctx: CtxT,
        route_static_ctx: RouteStaticCtx = .{},

        pub fn RouteStaticType(comptime route_index: usize) type {
            _ = route_index;
            return RouteStaticCtx;
        }

        pub fn routeStatic(self: *@This(), comptime route_index: usize) *RouteStaticCtx {
            _ = route_index;
            return &self.route_static_ctx;
        }

        pub fn routeStaticConst(self: *const @This(), comptime route_index: usize) *const RouteStaticCtx {
            _ = route_index;
            return &self.route_static_ctx;
        }

        pub fn handleHandlerError(_: *@This(), _: *Io.Writer, comptime _: type, _: anytype) Action {
            unreachable;
        }
    };
}

fn dispatchForTest(
    comptime S: type,
    ctx: anytype,
    allocator: Allocator,
    r: *Io.Reader,
    line: request.RequestLine,
    out: []u8,
) !struct { action: Action, len: usize } {
    const ServerT = TestServer(@TypeOf(ctx));
    var server: ServerT = .{
        .io = std.testing.io,
        .gpa = allocator,
        .ctx = ctx,
    };
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out);
    var stream: std.Io.net.Stream = undefined;
    const rid = S.match(line.method, line.path).?;
    const action = try S.dispatch(&server, allocator, r, &w, &stream, line, rid, params[0..S.MaxParams], 8 * 1024, 8 * 1024);
    return .{ .action = action, .len = w.end };
}

test "router: exact + param + glob" {
    const App = struct {};
    const S = Compiled(App, .{
        get("/a", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "a");
            }
        }),
        get("/u/{id}", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "u");
            }
        }),
        get("/g/*", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "g");
            }
        }),
        get("/ng/{*rest}", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ng");
            }
        }),
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

test "router: deep literal chain does not overflow pattern slot budget" {
    const S = Compiled(void, .{
        get("/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }),
    }, .{});

    var p = "/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p".*;
    try std.testing.expectEqual(@as(?u16, 0), S.match("GET", p[0..]));
}

test "router: trailing slash does not match exact literal" {
    const S = Compiled(void, .{
        get("/a", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "a");
            }
        }),
    }, .{});

    var p1 = "/a/".*;
    try std.testing.expectEqual(@as(?u16, null), S.match("GET", p1[0..]));
}

test "router: HEAD falls back to GET handler" {
    const S = Compiled(void, .{
        get("/x", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }),
    }, .{});

    var p = "/x".*;
    try std.testing.expectEqual(@as(?u16, 0), S.match("HEAD", p[0..]));
}

test "middleware Info: supports 'header: type = ...' form" {
    const Mw = struct {
        pub const Info = @import("middleware.zig").MiddlewareInfo{
            .name = "mw_needs",
            .header = struct {
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "x");
            }
        }),
    }, .{Mw});
}

test "middleware Info: supports header/query/path/data captures" {
    const Mw = struct {
        const AuthData = struct {
            seen: bool = false,
        };
        pub const Info = @import("middleware.zig").MiddlewareInfo{
            .name = "auth",
            .data = AuthData,
            .path = struct {
                id: parse.Int(u32),
            },
            .query = struct {
                q: parse.String,
            },
            .header = struct {
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                const auth = req.middlewareDataConst(.auth);
                return Res.text(200, if (auth.seen) "ok" else "bad-data");
            }
        }),
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "p");
            }
        }),
        get("/x", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "g");
            }
        }),
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

test "dispatch: expect middleware emits interim 100-continue before final response" {
    const ExpectMw = @import("middleware/expect.zig").Expect(.{});
    const S = Compiled(void, .{
        post("/echo", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                const body = try req.bodyAll(1024);
                return Res.text(200, body);
            }
        }),
    }, .{ExpectMw});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "POST /echo HTTP/1.1\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "hello",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [512]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expectEqual(.@"continue", res.action);
    const got = out[0..res.len];
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 100 Continue\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, got, "HTTP/1.1 200 OK\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nhello"));
}

test "dispatch: expect middleware rejects unsupported expectation with 417" {
    const ExpectMw = @import("middleware/expect.zig").Expect(.{});
    const S = Compiled(void, .{
        post("/x", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }),
    }, .{ExpectMw});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Expect: custom-expectation\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "hello",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [512]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expectEqual(.close, res.action);
    const got = out[0..res.len];
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 417 Expectation Failed\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, got, "100 Continue") == null);
    try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nexpectation failed\n"));
}

test "dispatch: expect middleware rejects 100-continue when content-length is zero" {
    const ExpectMw = @import("middleware/expect.zig").Expect(.{});
    const S = Compiled(void, .{
        post("/x", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }),
    }, .{ExpectMw});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [512]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expectEqual(.close, res.action);
    const got = out[0..res.len];
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 417 Expectation Failed\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, got, "100 Continue") == null);
    try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nexpectation failed\n"));
}

test "dispatch: expect middleware permissive mode allows 100-continue without body" {
    const ExpectMw = @import("middleware/expect.zig").Expect(.{ .allow_without_body = true });
    const S = Compiled(void, .{
        get("/x", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }),
    }, .{ExpectMw});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "GET /x HTTP/1.1\r\n" ++
            "Expect: 100-continue\r\n" ++
            "\r\n",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [512]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expectEqual(.@"continue", res.action);
    const got = out[0..res.len];
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, got, "100 Continue") == null);
    try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nok"));
}

test "dispatch: expect middleware emits interim 100-continue on post-handler drain" {
    const ExpectMw = @import("middleware/expect.zig").Expect(.{});
    const S = Compiled(void, .{
        post("/x", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }),
    }, .{ExpectMw});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "hello",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [512]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expectEqual(.@"continue", res.action);
    const got = out[0..res.len];
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 100 Continue\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, got, "HTTP/1.1 200 OK\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nok"));
}

test "dispatch: expect middleware uses original framing after earlier middleware drains chunked body" {
    const DrainMw = struct {
        pub const Info: middleware.MiddlewareInfo = .{ .name = "drain" };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            try req.discardUnreadBody();
            return rctx.next(req);
        }
    };
    const ExpectMw = @import("middleware/expect.zig").Expect(.{});
    const S = Compiled(void, .{
        post("/x", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }),
    }, .{ DrainMw, ExpectMw });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nhello\r\n0\r\n\r\n",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [512]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expectEqual(.@"continue", res.action);
    const got = out[0..res.len];
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, got, "100 Continue") == null);
    try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nok"));
}

test "dispatch: expect middleware uses original framing after earlier middleware drains content-length body" {
    const DrainMw = struct {
        pub const Info: middleware.MiddlewareInfo = .{ .name = "drain" };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            try req.discardUnreadBody();
            return rctx.next(req);
        }
    };
    const ExpectMw = @import("middleware/expect.zig").Expect(.{});
    const S = Compiled(void, .{
        post("/x", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }),
    }, .{ DrainMw, ExpectMw });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Expect: 100-continue\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "hello",
    );

    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [512]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expectEqual(.@"continue", res.action);
    const got = out[0..res.len];
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, got, "100 Continue") == null);
    try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nok"));
}

test "dispatch: pipelined request discards unread chunked body" {
    const S = Compiled(void, .{
        post("/x", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "p");
            }
        }),
        get("/x", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "g");
            }
        }),
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                return Res.text(200, req.paramValue(.id));
            }
        }),
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                return Res.text(200, req.paramValue(.rest));
            }
        }),
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

test "dispatch: typed path params via endpoint Info.path" {
    const S = Compiled(void, .{
        get("/u/{id}", struct {
            pub const Info: EndpointInfo = .{
                .path = struct {
                    id: parse.Int(u32),
                },
            };
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                const body = try std.fmt.allocPrint(req.allocator(), "{d}", .{req.paramValue(.id)});
                return Res.text(200, body);
            }
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
            pub const Info: EndpointInfo = .{
                .path = struct {
                    id: parse.Int(u32),
                },
            };
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "ok");
            }
        }),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /u/nope HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    var stream: std.Io.net.Stream = undefined;
    const ServerT = TestServer(void);
    var server: ServerT = .{ .io = std.testing.io, .gpa = a, .ctx = {} };
    const rid = S.match(line.method, line.path).?;
    try std.testing.expectError(error.BadValue, S.dispatch(&server, a, &r, &w, &stream, line, rid, params[0..S.MaxParams], 8 * 1024, 8 * 1024));
}

test "dispatch: typed path params with non-string parsers allocate zero" {
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
            pub const Info: EndpointInfo = .{
                .path = struct {
                    a: parse.Int(u32),
                    b: parse.Int(u32),
                    c: parse.Int(u32),
                    d: parse.Int(u32),
                },
            };
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                const sum: u32 = req.paramValue(.a) + req.paramValue(.b) + req.paramValue(.c) + req.paramValue(.d);
                return Res.text(200, if (sum == 10) "ok" else "bad");
            }
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                const body = try std.fmt.allocPrint(req.allocator(), "{d}", .{req.paramValue(.id)});
                return Res.text(200, body);
            }
        }),
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

test "dispatch: segmented response uses content-length" {
    const S = Compiled(void, .{
        get("/seg", struct {
            pub const Info: EndpointInfo = .{};
            const parts = [_][]const u8{ "ab", "cdef" };

            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response([][]const u8) {
                _ = req;
                return .{
                    .status = .ok,
                    .body = @constCast(parts[0..]),
                };
            }
        }),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /seg HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expectEqual(.@"continue", res.action);
    try std.testing.expect(std.mem.indexOf(u8, out[0..res.len], "content-length: 6\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\nabcdef"));
}

test "dispatch: custom body response uses chunked transfer-encoding" {
    const StreamEndpoint = struct {
        pub const Info: EndpointInfo = .{};

        const Body = struct {
            pub fn body(_: @This(), comptime rctx: ReqCtx, req: rctx.TReadOnly(), cw: *response.ChunkedWriter) !void {
                _ = req;
                try cw.writeAll("ab");
                try cw.writeAll("cd");
            }
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response(Body) {
            _ = req;
            return .{
                .status = .ok,
                .body = .{},
            };
        }
    };

    const S = Compiled(void, .{
        get("/stream", StreamEndpoint),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var r = Io.Reader.fixed("GET /stream HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [512]u8 = undefined;
    const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
    try std.testing.expectEqual(.@"continue", res.action);
    try std.testing.expect(std.mem.indexOf(u8, out[0..res.len], "transfer-encoding: chunked\r\n\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n"));
}

test "dispatch: middleware routes support void, segmented, and custom body responses" {
    const Pass = struct {
        pub const Info = @import("middleware.zig").MiddlewareInfo{ .name = "pass" };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Res() {
            return rctx.next(req);
        }
    };

    const parts = [_][]const u8{ "xy", "z" };

    const S = Compiled(void, .{
        get("/void", struct {
            pub const Info: EndpointInfo = .{ .middlewares = &.{Pass} };

            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response(void) {
                _ = req;
                return .{ .status = .no_content };
            }
        }),
        get("/parts", struct {
            pub const Info: EndpointInfo = .{ .middlewares = &.{Pass} };

            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response([][]const u8) {
                _ = req;
                return .{
                    .status = .ok,
                    .body = @constCast(parts[0..]),
                };
            }
        }),
        get("/stream", struct {
            pub const Info: EndpointInfo = .{ .middlewares = &.{Pass} };

            const Body = struct {
                pub fn body(_: @This(), comptime rctx: ReqCtx, req: rctx.TReadOnly(), cw: *response.ChunkedWriter) !void {
                    _ = req;
                    try cw.writeAll("mw");
                }
            };

            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response(Body) {
                _ = req;
                return .{ .status = .ok, .body = .{} };
            }
        }),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var r = Io.Reader.fixed("GET /void HTTP/1.1\r\n\r\n");
        const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
        var out: [256]u8 = undefined;
        const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
        try std.testing.expect(std.mem.indexOf(u8, out[0..res.len], "content-length: 0\r\n") != null);
    }
    {
        var r = Io.Reader.fixed("GET /parts HTTP/1.1\r\n\r\n");
        const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
        var out: [256]u8 = undefined;
        const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
        try std.testing.expect(std.mem.indexOf(u8, out[0..res.len], "content-length: 3\r\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "\r\n\r\nxyz"));
    }
    {
        var r = Io.Reader.fixed("GET /stream HTTP/1.1\r\n\r\n");
        const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
        var out: [256]u8 = undefined;
        const res = try dispatchForTest(S, {}, a, &r, line, out[0..]);
        try std.testing.expect(std.mem.indexOf(u8, out[0..res.len], "transfer-encoding: chunked\r\n\r\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, out[0..res.len], "2\r\nmw\r\n0\r\n\r\n"));
    }
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                const data = req.middlewareData(.auth);
                data.user_id += 1;
                return Res.text(200, if (data.user_id == 8) "ok" else "bad");
            }
        }),
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return error.Boom;
            }
        }),
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
        const RouteStaticCtx = struct {};
        io: Io,
        gpa: Allocator,
        ctx: void,
        called: *bool,
        route_static_ctx: RouteStaticCtx = .{},

        /// Returns static context type for route index.
        pub fn RouteStaticType(comptime route_index: usize) type {
            if (route_index != 0) @compileError("route index out of bounds");
            return RouteStaticCtx;
        }

        /// Returns mutable route static context by route index.
        pub fn routeStatic(self: *@This(), comptime route_index: usize) *RouteStaticCtx {
            if (route_index != 0) @compileError("route index out of bounds");
            return &self.route_static_ctx;
        }

        /// Returns const route static context by route index.
        pub fn routeStaticConst(self: *const @This(), comptime route_index: usize) *const RouteStaticCtx {
            if (route_index != 0) @compileError("route index out of bounds");
            return &self.route_static_ctx;
        }

        pub fn handleHandlerError(self: *@This(), _: *Io.Writer, comptime _: type, _: anytype) Action {
            self.called.* = true;
            return .close;
        }
    };
    var server: ServerT = .{
        .io = std.testing.io,
        .gpa = a,
        .ctx = {},
        .called = &called,
    };
    const rid = S.match(line.method, line.path).?;
    const action = try S.dispatch(&server, a, &r, &w, &stream, line, rid, params[0..S.MaxParams], 8 * 1024, 8 * 1024);
    try std.testing.expect(called);
    try std.testing.expectEqual(.close, action);
    try std.testing.expectEqual(@as(usize, 0), w.end);
}

test "fuzz: router match does not crash" {
    const S = Compiled(void, .{
        get("/a", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "a");
            }
        }),
        post("/b/{id}", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "b");
            }
        }),
        put("/c/*", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "c");
            }
        }),
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "x");
            }
        }),
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                const ctx = req.ctx();
                return Res.text(200, if (ctx.v == 1) "ok" else "bad");
            }
        }),
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

test "route helpers: method wrappers and Info propagation" {
    const Mw = struct {
        pub const Info: middleware.MiddlewareInfo = .{ .name = "mw" };
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            _ = req;
            return Res.text(200, "ok");
        }
    };
    const Op = struct {};
    const Endpoint = struct {
        pub const Info: EndpointInfo = .{
            .headers = struct { host: parse.Optional(parse.String) },
            .query = struct { page: parse.Optional(parse.Int(u16)) },
            .path = struct { id: parse.Int(u32) },
            .middlewares = &.{Mw},
            .operations = &.{Op},
        };
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            _ = req;
            return Res.text(200, "ok");
        }
    };

    const r_get = get("/g", Endpoint);
    const r_post = post("/p", Endpoint);
    const r_put = put("/u", Endpoint);
    const r_delete = delete("/d", Endpoint);
    const r_patch = patch("/x", Endpoint);
    const r_head = head("/h", Endpoint);
    const r_options = options("/o", Endpoint);
    const r_route = route(.TRACE, "/t", Endpoint);

    try std.testing.expectEqualStrings("GET", r_get.method);
    try std.testing.expectEqualStrings("POST", r_post.method);
    try std.testing.expectEqualStrings("PUT", r_put.method);
    try std.testing.expectEqualStrings("DELETE", r_delete.method);
    try std.testing.expectEqualStrings("PATCH", r_patch.method);
    try std.testing.expectEqualStrings("HEAD", r_head.method);
    try std.testing.expectEqualStrings("OPTIONS", r_options.method);
    try std.testing.expectEqualStrings("TRACE", r_route.method);
    try std.testing.expectEqualStrings("/t", r_route.pattern);
    try std.testing.expect(r_route.headers == Endpoint.Info.headers.?);
    try std.testing.expect(r_route.query == Endpoint.Info.query.?);
    try std.testing.expect(r_route.params == Endpoint.Info.path.?);
    try std.testing.expectEqual(@as(usize, 1), r_route.middlewares.len);
    try std.testing.expectEqual(@as(usize, 1), r_route.operations.len);
}

test "route: endpoint type accepted" {
    const Endpoint = struct {
        pub const Info: EndpointInfo = .{};
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            _ = req;
            return Res.text(200, "ok");
        }
    };

    const S = Compiled(void, .{
        get("/e", Endpoint),
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
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return Res.text(200, "x");
            }
        }),
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
    const ServerT = TestServer(void);
    var server: ServerT = .{ .io = std.testing.io, .gpa = a, .ctx = {} };
    const rid = S.match(line.method, line.path).?;
    try std.testing.expectError(error.InvalidPercentEncoding, S.dispatch(&server, a, &r, &w, &stream, line, rid, params[0..S.MaxParams], 8 * 1024, 8 * 1024));
}

test "dispatch: endpoint upgrade handles 101 and returns upgraded action" {
    const ServerT = struct {
        const RouteStaticCtx = struct {};
        io: Io,
        gpa: Allocator,
        ctx: void,
        upgraded: bool,
        route_static_ctx: RouteStaticCtx = .{},

        /// Returns static context type for route index.
        pub fn RouteStaticType(comptime route_index: usize) type {
            if (route_index != 0) @compileError("route index out of bounds");
            return RouteStaticCtx;
        }

        /// Returns mutable route static context by route index.
        pub fn routeStatic(self: *@This(), comptime route_index: usize) *RouteStaticCtx {
            if (route_index != 0) @compileError("route index out of bounds");
            return &self.route_static_ctx;
        }

        /// Returns const route static context by route index.
        pub fn routeStaticConst(self: *const @This(), comptime route_index: usize) *const RouteStaticCtx {
            if (route_index != 0) @compileError("route index out of bounds");
            return &self.route_static_ctx;
        }

        pub fn handleHandlerError(_: *@This(), _: *Io.Writer, comptime _: type, _: anytype) Action {
            unreachable;
        }
    };

    const Routes = struct {
        pub const Info: EndpointInfo = .{};
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
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

        pub fn upgrade(server: *ServerT, stream: *const std.Io.net.Stream, r: *Io.Reader, w: *Io.Writer, line: request.RequestLine, res: Res) void {
            return on_upgrade(server, stream, r, w, line, res);
        }
    };

    const S = Compiled(void, .{
        get("/ws", Routes),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var server: ServerT = .{
        .io = std.testing.io,
        .gpa = a,
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
    const action = try S.dispatch(&server, a, &r, &w, &stream, line, rid, params[0..S.MaxParams], 8 * 1024, 8 * 1024);

    try std.testing.expectEqual(Action.upgraded, action);
    try std.testing.expect(server.upgraded);
    const expected =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "connection: Upgrade\r\n" ++
        "upgrade: websocket\r\n" ++
        "\r\n";
    try std.testing.expectEqualStrings(expected, out[0..w.end]);
}

test "dispatch: endpoint without upgrade does not check status" {
    const S = Compiled(void, .{
        get("/ws", struct {
            pub const Info: EndpointInfo = .{};
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                _ = req;
                return .{
                    .status = .switching_protocols,
                    .headers = &.{
                        .{ .name = "connection", .value = "Upgrade" },
                        .{ .name = "upgrade", .value = "websocket" },
                    },
                };
            }
        }),
    }, .{});

    const ServerT = TestServer(void);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var server: ServerT = .{ .io = std.testing.io, .gpa = a, .ctx = {} };
    var r = Io.Reader.fixed("GET /ws HTTP/1.1\r\nHost: x\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    var stream: std.Io.net.Stream = undefined;
    const rid = S.match(line.method, line.path).?;
    const action = try S.dispatch(&server, a, &r, &w, &stream, line, rid, params[0..S.MaxParams], 8 * 1024, 8 * 1024);

    try std.testing.expectEqual(Action.@"continue", action);
    try std.testing.expect(std.mem.indexOf(u8, out[0..w.end], "content-length: 0\r\n") != null);
}

test "dispatch: endpoint with upgrade but non-101 does not call upgrade" {
    const ServerT = struct {
        const RouteStaticCtx = struct {};
        io: Io,
        gpa: Allocator,
        ctx: void,
        called: bool = false,
        route_static_ctx: RouteStaticCtx = .{},

        pub fn RouteStaticType(comptime route_index: usize) type {
            if (route_index != 0) @compileError("route index out of bounds");
            return RouteStaticCtx;
        }

        pub fn routeStatic(self: *@This(), comptime route_index: usize) *RouteStaticCtx {
            if (route_index != 0) @compileError("route index out of bounds");
            return &self.route_static_ctx;
        }

        pub fn routeStaticConst(self: *const @This(), comptime route_index: usize) *const RouteStaticCtx {
            if (route_index != 0) @compileError("route index out of bounds");
            return &self.route_static_ctx;
        }

        pub fn handleHandlerError(_: *@This(), _: *Io.Writer, comptime _: type, _: anytype) Action {
            unreachable;
        }
    };

    const Endpoint = struct {
        pub const Info: EndpointInfo = .{};

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            _ = req;
            return Res.text(200, "ok");
        }

        pub fn upgrade(server: *ServerT, _: *const std.Io.net.Stream, _: *Io.Reader, _: *Io.Writer, _: request.RequestLine, _: Res) void {
            server.called = true;
        }
    };

    const S = Compiled(void, .{
        get("/x", Endpoint),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var server: ServerT = .{ .io = std.testing.io, .gpa = a, .ctx = {} };
    var r = Io.Reader.fixed("GET /x HTTP/1.1\r\nHost: x\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(&r, 8 * 1024);
    var out: [256]u8 = undefined;
    var params: [S.MaxParams][]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    var stream: std.Io.net.Stream = undefined;
    const rid = S.match(line.method, line.path).?;
    const action = try S.dispatch(&server, a, &r, &w, &stream, line, rid, params[0..S.MaxParams], 8 * 1024, 8 * 1024);

    try std.testing.expectEqual(Action.@"continue", action);
    try std.testing.expect(!server.called);
}
