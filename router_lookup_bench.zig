const std = @import("std");
const util = @import("src/util.zig");

const Allocator = std.mem.Allocator;

const Method = enum(u8) {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS,
    HEAD,
};

const method_count = @typeInfo(Method).@"enum".fields.len;

const SegKind = enum(u8) {
    lit,
    param,
    glob,
};

const PatternSeg = struct {
    kind: SegKind,
    lit: []const u8 = &.{},
};

const Pattern = struct {
    segments: []PatternSeg,
    is_exact: bool,
};

const Route = struct {
    method: Method,
    pattern: Pattern,
    exact_path: ?[]const u8,
    route_index: u32,
};

const Lookup = struct {
    method: []const u8,
    path: []const u8,
};

const ExactEntry = struct {
    path: []const u8,
    hash: u64,
    route_index: u32,
};

const CurrentBucket = struct {
    exact_entries: []ExactEntry = &.{},
    exact_table: []u32 = &.{}, // 0 = empty, else entry_index + 1
    exact_mask: u64 = 0,
    pattern_route_indices: []u32 = &.{},
};

const CurrentRouter = struct {
    routes: []Route,
    buckets: [method_count]CurrentBucket,

    fn init(a: Allocator, routes: []Route) !CurrentRouter {
        var exact_counts: [method_count]usize = .{0} ** method_count;
        var pattern_counts: [method_count]usize = .{0} ** method_count;

        for (routes) |r| {
            const mi = @intFromEnum(r.method);
            if (r.exact_path != null) {
                exact_counts[mi] += 1;
            } else {
                pattern_counts[mi] += 1;
            }
        }

        var buckets: [method_count]CurrentBucket = undefined;
        for (0..method_count) |mi| {
            buckets[mi] = .{
                .exact_entries = try a.alloc(ExactEntry, exact_counts[mi]),
                .pattern_route_indices = try a.alloc(u32, pattern_counts[mi]),
            };
        }

        var exact_writes: [method_count]usize = .{0} ** method_count;
        var pattern_writes: [method_count]usize = .{0} ** method_count;

        for (routes) |r| {
            const mi = @intFromEnum(r.method);
            if (r.exact_path) |p| {
                const w = exact_writes[mi];
                buckets[mi].exact_entries[w] = .{
                    .path = p,
                    .hash = util.fnv1a64(p),
                    .route_index = r.route_index,
                };
                exact_writes[mi] = w + 1;
            } else {
                const w = pattern_writes[mi];
                buckets[mi].pattern_route_indices[w] = r.route_index;
                pattern_writes[mi] = w + 1;
            }
        }

        for (0..method_count) |mi| {
            const entries = buckets[mi].exact_entries;
            const cap = nextPow2AtLeastRuntime(entries.len * 2 + 1, 8);
            buckets[mi].exact_table = try a.alloc(u32, cap);
            @memset(buckets[mi].exact_table, 0);
            buckets[mi].exact_mask = @intCast(cap - 1);
            for (entries, 0..) |e, i| {
                var pos: u64 = e.hash & buckets[mi].exact_mask;
                while (true) : (pos = (pos + 1) & buckets[mi].exact_mask) {
                    const slot: usize = @intCast(pos);
                    if (buckets[mi].exact_table[slot] == 0) {
                        buckets[mi].exact_table[slot] = @intCast(i + 1);
                        break;
                    }
                }
            }
        }

        return .{
            .routes = routes,
            .buckets = buckets,
        };
    }

    fn match(self: *const CurrentRouter, method_token: []const u8, path: []const u8) ?u32 {
        const m = parseMethod(method_token) orelse return null;
        if (m == .HEAD) {
            if (self.matchInBucket(.HEAD, path)) |rid| return rid;
            return self.matchInBucket(.GET, path);
        }
        return self.matchInBucket(m, path);
    }

    fn matchInBucket(self: *const CurrentRouter, m: Method, path: []const u8) ?u32 {
        const b = &self.buckets[@intFromEnum(m)];
        if (findExact(b, path)) |rid| return rid;
        for (b.pattern_route_indices) |ri| {
            if (matchPattern(self.routes[ri].pattern, path)) return ri;
        }
        return null;
    }

    fn findExact(b: *const CurrentBucket, path: []const u8) ?u32 {
        if (b.exact_entries.len == 0) return null;
        const h = util.fnv1a64(path);
        var pos: u64 = h & b.exact_mask;
        var probe: usize = 0;
        while (probe < b.exact_table.len) : (probe += 1) {
            const slot = b.exact_table[@intCast(pos)];
            if (slot == 0) return null;
            const e = b.exact_entries[slot - 1];
            if (e.hash == h and std.mem.eql(u8, e.path, path)) return e.route_index;
            pos = (pos + 1) & b.exact_mask;
        }
        return null;
    }
};

const HashBucket = struct {
    exact: std.StringHashMapUnmanaged(u32) = .empty,
    pattern_route_indices: []u32 = &.{},
};

const HashRouter = struct {
    routes: []Route,
    buckets: [method_count]HashBucket,

    fn init(a: Allocator, routes: []Route) !HashRouter {
        var exact_counts: [method_count]usize = .{0} ** method_count;
        var pattern_counts: [method_count]usize = .{0} ** method_count;

        for (routes) |r| {
            const mi = @intFromEnum(r.method);
            if (r.exact_path != null) {
                exact_counts[mi] += 1;
            } else {
                pattern_counts[mi] += 1;
            }
        }

        var buckets: [method_count]HashBucket = undefined;
        for (0..method_count) |mi| {
            buckets[mi] = .{
                .pattern_route_indices = try a.alloc(u32, pattern_counts[mi]),
            };
            try buckets[mi].exact.ensureTotalCapacity(a, @intCast(exact_counts[mi]));
        }

        var pattern_writes: [method_count]usize = .{0} ** method_count;
        for (routes) |r| {
            const mi = @intFromEnum(r.method);
            if (r.exact_path) |p| {
                buckets[mi].exact.putAssumeCapacity(p, r.route_index);
            } else {
                const w = pattern_writes[mi];
                buckets[mi].pattern_route_indices[w] = r.route_index;
                pattern_writes[mi] = w + 1;
            }
        }

        return .{
            .routes = routes,
            .buckets = buckets,
        };
    }

    fn deinit(self: *HashRouter, a: Allocator) void {
        for (&self.buckets) |*b| b.exact.deinit(a);
    }

    fn match(self: *const HashRouter, method_token: []const u8, path: []const u8) ?u32 {
        const m = parseMethod(method_token) orelse return null;
        if (m == .HEAD) {
            if (self.matchInBucket(.HEAD, path)) |rid| return rid;
            return self.matchInBucket(.GET, path);
        }
        return self.matchInBucket(m, path);
    }

    fn matchInBucket(self: *const HashRouter, m: Method, path: []const u8) ?u32 {
        const b = &self.buckets[@intFromEnum(m)];
        if (b.exact.get(path)) |rid| return rid;
        for (b.pattern_route_indices) |ri| {
            if (matchPattern(self.routes[ri].pattern, path)) return ri;
        }
        return null;
    }
};

const CuckooExactEntry = struct {
    path: []const u8,
    h1: u64,
    h2: u64,
    route_index: u32,
};

const CuckooBucket = struct {
    exact_entries: []CuckooExactEntry = &.{},
    exact_table: []u32 = &.{}, // 0 = empty, else entry_index + 1
    exact_mask: u64 = 0,
    overflow_entry_indices: []u32 = &.{},
    overflow_len: usize = 0,
    pattern_route_indices: []u32 = &.{},

    fn insertCuckoo(self: *CuckooBucket, entry_index: u32, max_kicks: usize) bool {
        const e = self.exact_entries[entry_index];
        const pos1: usize = @intCast(e.h1 & self.exact_mask);
        if (self.exact_table[pos1] == 0) {
            self.exact_table[pos1] = entry_index + 1;
            return true;
        }

        const pos2: usize = @intCast(e.h2 & self.exact_mask);
        if (self.exact_table[pos2] == 0) {
            self.exact_table[pos2] = entry_index + 1;
            return true;
        }

        var cur = entry_index;
        var pos = pos1;
        var kick: usize = 0;
        while (kick < max_kicks) : (kick += 1) {
            const displaced = self.exact_table[pos];
            self.exact_table[pos] = cur + 1;
            cur = displaced - 1;

            const d = self.exact_entries[cur];
            const d_pos1: usize = @intCast(d.h1 & self.exact_mask);
            const d_pos2: usize = @intCast(d.h2 & self.exact_mask);
            const alt = if (pos == d_pos1) d_pos2 else d_pos1;
            if (self.exact_table[alt] == 0) {
                self.exact_table[alt] = cur + 1;
                return true;
            }
            pos = alt;
        }
        return false;
    }

    fn slotMatch(self: *const CuckooBucket, path: []const u8, hash: u64, slot_pos: usize) ?u32 {
        const slot = self.exact_table[slot_pos];
        if (slot == 0) return null;
        const e = self.exact_entries[slot - 1];
        if (e.h1 == hash and std.mem.eql(u8, e.path, path)) return e.route_index;
        return null;
    }

    fn findExact(self: *const CuckooBucket, path: []const u8) ?u32 {
        if (self.exact_entries.len == 0) return null;

        const h1 = util.fnv1a64(path);
        const h2 = cuckooSecondaryHash(h1);

        const p1: usize = @intCast(h1 & self.exact_mask);
        if (self.slotMatch(path, h1, p1)) |rid| return rid;

        const p2: usize = @intCast(h2 & self.exact_mask);
        if (p2 != p1) {
            const slot = self.exact_table[p2];
            if (slot != 0) {
                const e = self.exact_entries[slot - 1];
                if (e.h2 == h2 and std.mem.eql(u8, e.path, path)) return e.route_index;
            }
        }

        for (self.overflow_entry_indices[0..self.overflow_len]) |i| {
            const e = self.exact_entries[i];
            if (e.h1 == h1 and std.mem.eql(u8, e.path, path)) return e.route_index;
        }
        return null;
    }
};

const CuckooRouter = struct {
    routes: []Route,
    buckets: [method_count]CuckooBucket,

    fn init(a: Allocator, routes: []Route) !CuckooRouter {
        var exact_counts: [method_count]usize = .{0} ** method_count;
        var pattern_counts: [method_count]usize = .{0} ** method_count;

        for (routes) |r| {
            const mi = @intFromEnum(r.method);
            if (r.exact_path != null) {
                exact_counts[mi] += 1;
            } else {
                pattern_counts[mi] += 1;
            }
        }

        var buckets: [method_count]CuckooBucket = undefined;
        for (0..method_count) |mi| {
            buckets[mi] = .{
                .exact_entries = try a.alloc(CuckooExactEntry, exact_counts[mi]),
                .overflow_entry_indices = try a.alloc(u32, exact_counts[mi]),
                .pattern_route_indices = try a.alloc(u32, pattern_counts[mi]),
            };
        }

        var exact_writes: [method_count]usize = .{0} ** method_count;
        var pattern_writes: [method_count]usize = .{0} ** method_count;

        for (routes) |r| {
            const mi = @intFromEnum(r.method);
            if (r.exact_path) |p| {
                const w = exact_writes[mi];
                const h1 = util.fnv1a64(p);
                buckets[mi].exact_entries[w] = .{
                    .path = p,
                    .h1 = h1,
                    .h2 = cuckooSecondaryHash(h1),
                    .route_index = r.route_index,
                };
                exact_writes[mi] = w + 1;
            } else {
                const w = pattern_writes[mi];
                buckets[mi].pattern_route_indices[w] = r.route_index;
                pattern_writes[mi] = w + 1;
            }
        }

        for (0..method_count) |mi| {
            const b = &buckets[mi];
            if (b.exact_entries.len == 0) continue;

            const cap = nextPow2AtLeastRuntime(b.exact_entries.len * 2 + 1, 8);
            b.exact_table = try a.alloc(u32, cap);
            @memset(b.exact_table, 0);
            b.exact_mask = @intCast(cap - 1);

            for (0..b.exact_entries.len) |i| {
                const inserted = b.insertCuckoo(@intCast(i), 64);
                if (!inserted) {
                    b.overflow_entry_indices[b.overflow_len] = @intCast(i);
                    b.overflow_len += 1;
                }
            }
        }

        return .{
            .routes = routes,
            .buckets = buckets,
        };
    }

    fn match(self: *const CuckooRouter, method_token: []const u8, path: []const u8) ?u32 {
        const m = parseMethod(method_token) orelse return null;
        if (m == .HEAD) {
            if (self.matchInBucket(.HEAD, path)) |rid| return rid;
            return self.matchInBucket(.GET, path);
        }
        return self.matchInBucket(m, path);
    }

    fn matchInBucket(self: *const CuckooRouter, m: Method, path: []const u8) ?u32 {
        const b = &self.buckets[@intFromEnum(m)];
        if (b.findExact(path)) |rid| return rid;
        for (b.pattern_route_indices) |ri| {
            if (matchPattern(self.routes[ri].pattern, path)) return ri;
        }
        return null;
    }
};

const TempTrieNode = struct {
    terminal_route: ?u32 = null,
    glob_route: ?u32 = null,
    param_child: ?u32 = null,
    lit_names: std.ArrayListUnmanaged([]const u8) = .empty,
    lit_children: std.ArrayListUnmanaged(u32) = .empty,
};

const TempTrieBucket = struct {
    nodes: std.ArrayListUnmanaged(TempTrieNode) = .empty,

    fn init(a: Allocator) !TempTrieBucket {
        var b: TempTrieBucket = .{};
        try b.nodes.append(a, .{});
        return b;
    }

    fn newNode(self: *TempTrieBucket, a: Allocator) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(a, .{});
        return idx;
    }

    fn findLitChild(self: *const TempTrieBucket, node_idx: u32, part: []const u8) ?u32 {
        const n = &self.nodes.items[node_idx];
        for (n.lit_names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, part)) return n.lit_children.items[i];
        }
        return null;
    }

    fn insertRoute(self: *TempTrieBucket, a: Allocator, route: Route) !void {
        var node_idx: u32 = 0;
        for (route.pattern.segments) |seg| {
            switch (seg.kind) {
                .lit => {
                    if (self.findLitChild(node_idx, seg.lit)) |child_idx| {
                        node_idx = child_idx;
                    } else {
                        const child_idx = try self.newNode(a);
                        var n = &self.nodes.items[node_idx];
                        try n.lit_names.append(a, seg.lit);
                        try n.lit_children.append(a, child_idx);
                        node_idx = child_idx;
                    }
                },
                .param => {
                    var n = &self.nodes.items[node_idx];
                    if (n.param_child) |child_idx| {
                        node_idx = child_idx;
                    } else {
                        const child_idx = try self.newNode(a);
                        n = &self.nodes.items[node_idx];
                        n.param_child = child_idx;
                        node_idx = child_idx;
                    }
                },
                .glob => {
                    var n = &self.nodes.items[node_idx];
                    if (n.glob_route == null) n.glob_route = route.route_index;
                    return;
                },
            }
        }
        var n = &self.nodes.items[node_idx];
        if (n.terminal_route == null) n.terminal_route = route.route_index;
    }
};

const RadixEdge = struct {
    labels: []const []const u8,
    child: u32,
};

const RadixNode = struct {
    terminal_route: ?u32 = null,
    glob_route: ?u32 = null,
    param_child: ?u32 = null,
    lit_edges: std.StringHashMapUnmanaged(u32) = .empty,
};

const ParsedSeg = struct {
    part: []const u8,
    next_pos: usize,
};

const RadixBucket = struct {
    nodes: std.ArrayListUnmanaged(RadixNode) = .empty,
    edges: std.ArrayListUnmanaged(RadixEdge) = .empty,

    fn init(a: Allocator, routes: []Route, method: Method) !RadixBucket {
        var temp = try TempTrieBucket.init(a);
        for (routes) |r| {
            if (r.method == method) try temp.insertRoute(a, r);
        }

        var bucket: RadixBucket = .{};
        _ = try bucket.compileNode(a, &temp, 0);
        return bucket;
    }

    fn compileNode(self: *RadixBucket, a: Allocator, temp: *const TempTrieBucket, temp_idx: u32) !u32 {
        const temp_node = &temp.nodes.items[temp_idx];
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(a, .{
            .terminal_route = temp_node.terminal_route,
            .glob_route = temp_node.glob_route,
        });

        if (temp_node.param_child) |param_child| {
            const compiled_param_child = try self.compileNode(a, temp, param_child);
            self.nodes.items[idx].param_child = compiled_param_child;
        }

        for (temp_node.lit_names.items, 0..) |first_label, child_idx| {
            var labels: std.ArrayListUnmanaged([]const u8) = .empty;
            try labels.append(a, first_label);

            var walk_idx = temp_node.lit_children.items[child_idx];
            while (true) {
                const walk = &temp.nodes.items[walk_idx];
                const collapsible = walk.terminal_route == null and
                    walk.glob_route == null and
                    walk.param_child == null and
                    walk.lit_names.items.len == 1;
                if (!collapsible) break;
                try labels.append(a, walk.lit_names.items[0]);
                walk_idx = walk.lit_children.items[0];
            }

            const child = try self.compileNode(a, temp, walk_idx);
            const edge_idx: u32 = @intCast(self.edges.items.len);
            try self.edges.append(a, .{
                .labels = try labels.toOwnedSlice(a),
                .child = child,
            });
            try self.nodes.items[idx].lit_edges.put(a, first_label, edge_idx);
        }

        return idx;
    }

    fn match(self: *const RadixBucket, path: []const u8) ?u32 {
        if (path.len == 0 or path[0] != '/') return null;
        const start_pos: usize = if (path.len == 1) 2 else 1;
        return self.matchFrom(0, path, start_pos);
    }

    fn matchFrom(self: *const RadixBucket, node_idx: u32, path: []const u8, pos: usize) ?u32 {
        const node = &self.nodes.items[node_idx];
        if (pos == path.len + 1) return node.terminal_route orelse node.glob_route;

        const parsed = parseNextSeg(path, pos) orelse return node.glob_route;

        if (node.lit_edges.get(parsed.part)) |edge_idx| {
            if (self.matchEdge(edge_idx, path, parsed.next_pos)) |after_edge_pos| {
                if (self.matchFrom(self.edges.items[edge_idx].child, path, after_edge_pos)) |rid| return rid;
            }
        }

        if (node.param_child) |param_child| {
            if (self.matchFrom(param_child, path, parsed.next_pos)) |rid| return rid;
        }

        return node.glob_route;
    }

    fn matchEdge(self: *const RadixBucket, edge_idx: u32, path: []const u8, pos_after_first: usize) ?usize {
        const edge = self.edges.items[edge_idx];
        var pos = pos_after_first;
        var i: usize = 1;
        while (i < edge.labels.len) : (i += 1) {
            const parsed = parseNextSeg(path, pos) orelse return null;
            if (!std.mem.eql(u8, parsed.part, edge.labels[i])) return null;
            pos = parsed.next_pos;
        }
        return pos;
    }

    fn debug(self: *const RadixBucket, path: []const u8) void {
        if (path.len == 0 or path[0] != '/') {
            std.debug.print("invalid path\n", .{});
            return;
        }
        const start_pos: usize = if (path.len == 1) 2 else 1;
        self.debugFrom(0, path, start_pos, 0);
    }

    fn debugFrom(self: *const RadixBucket, node_idx: u32, path: []const u8, pos: usize, depth: usize) void {
        const node = &self.nodes.items[node_idx];
        std.debug.print(
            "{s}node {d}: terminal={any} glob={any} param={any} lit_count={d} pos={d}\n",
            .{ indent(depth), node_idx, node.terminal_route, node.glob_route, node.param_child, node.lit_edges.size, pos },
        );
        if (pos == path.len + 1) {
            std.debug.print("{s}done\n", .{indent(depth)});
            return;
        }

        const parsed = parseNextSeg(path, pos) orelse {
            std.debug.print("{s}parse failed at pos={d}\n", .{ indent(depth), pos });
            return;
        };
        std.debug.print("{s}seg={s} next={d}\n", .{ indent(depth), parsed.part, parsed.next_pos });

        if (node.lit_edges.get(parsed.part)) |edge_idx| {
            const edge = self.edges.items[edge_idx];
            std.debug.print("{s}lit edge {d} labels=", .{ indent(depth), edge_idx });
            for (edge.labels) |label| std.debug.print("{s}/", .{label});
            std.debug.print(" child={d}\n", .{edge.child});
            if (self.matchEdge(edge_idx, path, parsed.next_pos)) |after_edge_pos| {
                std.debug.print("{s}edge matched -> pos={d}\n", .{ indent(depth), after_edge_pos });
                self.debugFrom(edge.child, path, after_edge_pos, depth + 1);
            } else {
                std.debug.print("{s}edge mismatch\n", .{indent(depth)});
            }
        } else {
            std.debug.print("{s}no literal edge\n", .{indent(depth)});
        }

        if (node.param_child) |param_child| {
            std.debug.print("{s}try param child {d}\n", .{ indent(depth), param_child });
            self.debugFrom(param_child, path, parsed.next_pos, depth + 1);
        } else {
            std.debug.print("{s}no param child\n", .{indent(depth)});
        }
    }
};

const RadixHashRouter = struct {
    buckets: [method_count]RadixBucket,

    fn init(a: Allocator, routes: []Route) !RadixHashRouter {
        var buckets: [method_count]RadixBucket = undefined;
        for (0..method_count) |mi| {
            buckets[mi] = try RadixBucket.init(a, routes, @enumFromInt(mi));
        }
        return .{ .buckets = buckets };
    }

    fn match(self: *const RadixHashRouter, method_token: []const u8, path: []const u8) ?u32 {
        const m = parseMethod(method_token) orelse return null;
        if (m == .HEAD) {
            if (self.buckets[@intFromEnum(Method.HEAD)].match(path)) |rid| return rid;
            return self.buckets[@intFromEnum(Method.GET)].match(path);
        }
        return self.buckets[@intFromEnum(m)].match(path);
    }

    fn debugMatch(self: *const RadixHashRouter, method_token: []const u8, path: []const u8) void {
        const m = parseMethod(method_token) orelse {
            std.debug.print("bad method: {s}\n", .{method_token});
            return;
        };
        std.debug.print("radix debug: method={s} path={s}\n", .{ method_token, path });
        self.buckets[@intFromEnum(m)].debug(path);
    }
};

const RunResult = struct {
    total_ns: u64,
    ns_per_lookup: f64,
};

fn parsePattern(a: Allocator, pattern: []const u8) !Pattern {
    if (pattern.len == 0 or pattern[0] != '/') return error.InvalidPattern;
    if (std.mem.eql(u8, pattern, "/")) return .{ .segments = &.{}, .is_exact = true };

    var segs: std.ArrayList(PatternSeg) = .empty;
    defer segs.deinit(a);

    var i: usize = 1;
    var is_exact = true;

    while (i <= pattern.len) {
        const slash = std.mem.indexOfScalarPos(u8, pattern, i, '/') orelse pattern.len;
        const part = pattern[i..slash];
        if (part.len == 0) return error.InvalidPattern;

        if (std.mem.eql(u8, part, "*")) {
            if (slash != pattern.len) return error.InvalidPattern;
            is_exact = false;
            try segs.append(a, .{ .kind = .glob });
            break;
        }
        if (part.len >= 4 and part[0] == '{' and part[1] == '*' and part[part.len - 1] == '}') {
            if (slash != pattern.len) return error.InvalidPattern;
            is_exact = false;
            try segs.append(a, .{ .kind = .glob });
            break;
        }
        if (part.len >= 3 and part[0] == '{' and part[part.len - 1] == '}') {
            is_exact = false;
            try segs.append(a, .{ .kind = .param });
        } else {
            try segs.append(a, .{ .kind = .lit, .lit = part });
        }

        if (slash == pattern.len) break;
        i = slash + 1;
    }

    return .{
        .segments = try segs.toOwnedSlice(a),
        .is_exact = is_exact,
    };
}

fn matchPattern(p: Pattern, path: []const u8) bool {
    if (p.segments.len == 0) return path.len == 1 and path[0] == '/';
    if (path.len == 0 or path[0] != '/') return false;

    var path_i: usize = 1;
    var si: usize = 0;
    while (si < p.segments.len) : (si += 1) {
        const seg = p.segments[si];
        if (seg.kind == .glob) return true;
        if (path_i > path.len) return false;

        const next_slash = std.mem.indexOfScalarPos(u8, path, path_i, '/') orelse path.len;
        const part = path[path_i..next_slash];
        if (part.len == 0) return false;

        switch (seg.kind) {
            .lit => if (!std.mem.eql(u8, part, seg.lit)) return false,
            .param => {},
            .glob => unreachable,
        }

        path_i = next_slash + 1;
    }
    return path_i > path.len;
}

fn parseMethod(token: []const u8) ?Method {
    if (std.mem.eql(u8, token, "GET")) return .GET;
    if (std.mem.eql(u8, token, "POST")) return .POST;
    if (std.mem.eql(u8, token, "PUT")) return .PUT;
    if (std.mem.eql(u8, token, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, token, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, token, "OPTIONS")) return .OPTIONS;
    if (std.mem.eql(u8, token, "HEAD")) return .HEAD;
    return null;
}

fn parseNextSeg(path: []const u8, pos: usize) ?ParsedSeg {
    if (pos > path.len) return null;
    const next_slash = std.mem.indexOfScalarPos(u8, path, pos, '/') orelse path.len;
    const part = path[pos..next_slash];
    if (part.len == 0) return null;
    return .{
        .part = part,
        .next_pos = if (next_slash == path.len) path.len + 1 else next_slash + 1,
    };
}

fn indent(depth: usize) []const u8 {
    return switch (depth) {
        0 => "",
        1 => "  ",
        2 => "    ",
        3 => "      ",
        4 => "        ",
        else => "          ",
    };
}

fn methodToken(m: Method) []const u8 {
    return switch (m) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .OPTIONS => "OPTIONS",
        .HEAD => "HEAD",
    };
}

fn nextPow2AtLeastRuntime(n: usize, min: usize) usize {
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

fn cuckooSecondaryHash(h1: u64) u64 {
    var x = h1 ^ 0x9e37_79b9_7f4a_7c15;
    x ^= x >> 30;
    x *%= 0xbf58_476d_1ce4_e5b9;
    x ^= x >> 27;
    x *%= 0x94d0_49bb_1331_11eb;
    x ^= x >> 31;
    return x;
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    if (rc != 0) unreachable;
    return (@as(u64, @intCast(ts.sec)) * @as(u64, std.time.ns_per_s)) + @as(u64, @intCast(ts.nsec));
}

fn buildRoutesAndLookups(a: Allocator, n: usize) !struct { routes: []Route, lookups: []Lookup } {
    const routes = try a.alloc(Route, n);
    const lookups = try a.alloc(Lookup, n);

    for (0..n) |i| {
        var m: Method = switch (i % 6) {
            0 => .GET,
            1 => .POST,
            2 => .PUT,
            3 => .DELETE,
            4 => .PATCH,
            else => .OPTIONS,
        };
        if (i % 40 == 0) m = .HEAD;

        const pattern_str, const concrete_path = blk: {
            if (i % 25 == 0) {
                const p = try std.fmt.allocPrint(a, "/g{d}/{{*rest}}", .{i});
                const c = try std.fmt.allocPrint(a, "/g{d}/a/b/c", .{i});
                break :blk .{ p, c };
            }
            if (i % 10 == 0) {
                const p = try std.fmt.allocPrint(a, "/p{d}/{{id}}", .{i});
                const c = try std.fmt.allocPrint(a, "/p{d}/{d}", .{ i, (i % 997) + 1 });
                break :blk .{ p, c };
            }
            const p = try std.fmt.allocPrint(a, "/r{d}", .{i});
            break :blk .{ p, p };
        };

        const pat = try parsePattern(a, pattern_str);
        routes[i] = .{
            .method = m,
            .pattern = pat,
            .exact_path = if (pat.is_exact) pattern_str else null,
            .route_index = @intCast(i),
        };
        lookups[i] = .{
            .method = methodToken(m),
            .path = concrete_path,
        };
    }

    return .{ .routes = routes, .lookups = lookups };
}

fn buildLookupIndices(a: Allocator, route_count: usize, lookup_count: usize) ![]u32 {
    const ids = try a.alloc(u32, lookup_count);
    var prng = std.Random.DefaultPrng.init(0x5a17_200d_cafe_babe);
    const random = prng.random();
    for (ids) |*id| {
        id.* = @intCast(random.uintLessThan(usize, route_count));
    }
    return ids;
}

fn runCurrentLookup(
    r: *const CurrentRouter,
    lookups: []const Lookup,
    lookup_ids: []const u32,
    total_lookups: usize,
) RunResult {
    var checksum: u64 = 0;
    const start_ns = monotonicNowNs();

    var i: usize = 0;
    while (i < total_lookups) : (i += 1) {
        const l = lookups[lookup_ids[i % lookup_ids.len]];
        const rid = r.match(l.method, l.path) orelse unreachable;
        checksum +%= rid;
    }

    const ns = monotonicNowNs() - start_ns;
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .total_ns = ns,
        .ns_per_lookup = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(total_lookups)),
    };
}

fn runHashLookup(
    r: *const HashRouter,
    lookups: []const Lookup,
    lookup_ids: []const u32,
    total_lookups: usize,
) RunResult {
    var checksum: u64 = 0;
    const start_ns = monotonicNowNs();

    var i: usize = 0;
    while (i < total_lookups) : (i += 1) {
        const l = lookups[lookup_ids[i % lookup_ids.len]];
        const rid = r.match(l.method, l.path) orelse unreachable;
        checksum +%= rid;
    }

    const ns = monotonicNowNs() - start_ns;
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .total_ns = ns,
        .ns_per_lookup = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(total_lookups)),
    };
}

fn runRadixLookup(
    r: *const RadixHashRouter,
    lookups: []const Lookup,
    lookup_ids: []const u32,
    total_lookups: usize,
) RunResult {
    var checksum: u64 = 0;
    const start_ns = monotonicNowNs();

    var i: usize = 0;
    while (i < total_lookups) : (i += 1) {
        const l = lookups[lookup_ids[i % lookup_ids.len]];
        const rid = r.match(l.method, l.path) orelse unreachable;
        checksum +%= rid;
    }

    const ns = monotonicNowNs() - start_ns;
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .total_ns = ns,
        .ns_per_lookup = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(total_lookups)),
    };
}

fn runCuckooLookup(
    r: *const CuckooRouter,
    lookups: []const Lookup,
    lookup_ids: []const u32,
    total_lookups: usize,
) RunResult {
    var checksum: u64 = 0;
    const start_ns = monotonicNowNs();

    var i: usize = 0;
    while (i < total_lookups) : (i += 1) {
        const l = lookups[lookup_ids[i % lookup_ids.len]];
        const rid = r.match(l.method, l.path) orelse unreachable;
        checksum +%= rid;
    }

    const ns = monotonicNowNs() - start_ns;
    std.mem.doNotOptimizeAway(checksum);
    return .{
        .total_ns = ns,
        .ns_per_lookup = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(total_lookups)),
    };
}

fn avgNs(results: []const RunResult) f64 {
    var total: f64 = 0;
    for (results) |r| total += r.ns_per_lookup;
    return total / @as(f64, @floatFromInt(results.len));
}

fn verifyRouters(
    current: *const CurrentRouter,
    hash: *const HashRouter,
    radix: *const RadixHashRouter,
    lookups: []const Lookup,
) !void {
    for (lookups, 0..) |l, i| {
        const expected = current.match(l.method, l.path) orelse return error.CurrentRouterMissedLookup;
        const got_hash = hash.match(l.method, l.path) orelse {
            std.debug.print("hash missed lookup {d}: {s} {s}\n", .{ i, l.method, l.path });
            return error.HashRouterMissedLookup;
        };
        const got_radix = radix.match(l.method, l.path) orelse {
            std.debug.print("radix missed lookup {d}: {s} {s}, expected={d}\n", .{ i, l.method, l.path, expected });
            radix.debugMatch(l.method, l.path);
            return error.RadixRouterMissedLookup;
        };

        if (got_hash != expected or got_radix != expected) {
            std.debug.print(
                "router mismatch at lookup {d}: {s} {s} -> current={d} hash={d} radix={d}\n",
                .{ i, l.method, l.path, expected, got_hash, got_radix },
            );
            return error.RouterMismatch;
        }
    }
}

fn runCase(a: Allocator, route_count: usize, label: []const u8) !void {
    const lookup_count = 200_000;
    const total_lookups = 5_000_000;
    const runs = 6;

    const built = try buildRoutesAndLookups(a, route_count);
    const lookup_ids = try buildLookupIndices(a, route_count, lookup_count);

    const current = try CurrentRouter.init(a, built.routes);
    var hash = try HashRouter.init(a, built.routes);
    defer hash.deinit(a);
    const radix = try RadixHashRouter.init(a, built.routes);

    try verifyRouters(&current, &hash, &radix, built.lookups);

    // Warm all routers.
    _ = runCurrentLookup(&current, built.lookups, lookup_ids, lookup_count);
    _ = runHashLookup(&hash, built.lookups, lookup_ids, lookup_count);
    _ = runRadixLookup(&radix, built.lookups, lookup_ids, lookup_count);

    var current_runs: [runs]RunResult = undefined;
    var hash_runs: [runs]RunResult = undefined;
    var radix_runs: [runs]RunResult = undefined;

    // Interleave runs to reduce drift/bias.
    for (0..runs) |i| {
        current_runs[i] = runCurrentLookup(&current, built.lookups, lookup_ids, total_lookups);
        hash_runs[i] = runHashLookup(&hash, built.lookups, lookup_ids, total_lookups);
        radix_runs[i] = runRadixLookup(&radix, built.lookups, lookup_ids, total_lookups);
    }

    const cur_avg = avgNs(&current_runs);
    const hash_avg = avgNs(&hash_runs);
    const radix_avg = avgNs(&radix_runs);
    const hash_rel = hash_avg / cur_avg;
    const radix_rel = radix_avg / cur_avg;
    const radix_vs_hash = radix_avg / hash_avg;

    std.debug.print("== {s} ({d} routes) ==\n", .{ label, route_count });
    std.debug.print("current-style router avg: {d:.3} ns/lookup\n", .{cur_avg});
    std.debug.print("hash full router avg:     {d:.3} ns/lookup\n", .{hash_avg});
    std.debug.print("radix-hash router avg:    {d:.3} ns/lookup\n", .{radix_avg});
    std.debug.print("relative: hash/current = {d:.3}x\n", .{hash_rel});
    std.debug.print("relative: radix/current = {d:.3}x\n", .{radix_rel});
    std.debug.print("relative: radix/hash = {d:.3}x\n\n", .{radix_vs_hash});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    std.debug.print(
        \\Full router benchmark (router-vs-router)
        \\Build: ReleaseFast (`zig run -O ReleaseFast -lc router_lookup_bench.zig`)
        \\Workload: method dispatch + exact lookup + pattern fallback + HEAD->GET fallback
        \\Runs: 6 per case, 5,000,000 lookups per run
        \\
        \\
    , .{});

    try runCase(a, 500, "0.5k");
    try runCase(a, 5_000, "5k");
    try runCase(a, 50_000, "50k");
}
