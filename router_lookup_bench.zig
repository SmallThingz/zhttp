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

const max_path_segments = 16;

const DecodedPath = struct {
    path: []const u8,
    path_hash: u64,
    seg_count: u8,
    segs: [max_path_segments][]const u8,
    seg_hashes: [max_path_segments]u64,
};

const FlatTable = struct {
    slots: []u32 = &.{}, // 0 = empty, else entry_index + 1
    mask: u64 = 0,

    fn init(a: Allocator, count: usize) !FlatTable {
        const cap = nextPow2AtLeastRuntime(count * 2 + 1, 8);
        const slots = try a.alloc(u32, cap);
        @memset(slots, 0);
        return .{
            .slots = slots,
            .mask = @intCast(cap - 1),
        };
    }

    fn insert(self: *FlatTable, hash: u64, entry_index: u32) void {
        var pos: u64 = hash & self.mask;
        while (true) : (pos = (pos + 1) & self.mask) {
            const slot_idx: usize = @intCast(pos);
            if (self.slots[slot_idx] == 0) {
                self.slots[slot_idx] = entry_index + 1;
                return;
            }
        }
    }
};

const ExactPathEntry = struct {
    path: []const u8,
    hash: u64,
    route_index: u32,
};

const TempPatternNode = struct {
    end_route: ?u32 = null,
    glob_route: ?u32 = null,
    param_child: ?u32 = null,
    lit_names: std.ArrayListUnmanaged([]const u8) = .empty,
    lit_children: std.ArrayListUnmanaged(u32) = .empty,
};

const TempPatternBucket = struct {
    nodes: std.ArrayListUnmanaged(TempPatternNode) = .empty,

    fn init(a: Allocator) !TempPatternBucket {
        var bucket: TempPatternBucket = .{};
        try bucket.nodes.append(a, .{});
        return bucket;
    }

    fn newNode(self: *TempPatternBucket, a: Allocator) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(a, .{});
        return idx;
    }

    fn findLiteralChild(self: *const TempPatternBucket, node_idx: u32, lit: []const u8) ?u32 {
        const node = &self.nodes.items[node_idx];
        for (node.lit_names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, lit)) return node.lit_children.items[i];
        }
        return null;
    }

    fn setMin(slot: *?u32, value: u32) void {
        if (slot.*) |existing| {
            if (value < existing) slot.* = value;
        } else {
            slot.* = value;
        }
    }

    fn insertRoute(self: *TempPatternBucket, a: Allocator, route: Route) !void {
        var node_idx: u32 = 0;
        for (route.pattern.segments) |seg| {
            switch (seg.kind) {
                .lit => {
                    if (self.findLiteralChild(node_idx, seg.lit)) |child_idx| {
                        node_idx = child_idx;
                    } else {
                        const child_idx = try self.newNode(a);
                        var node = &self.nodes.items[node_idx];
                        try node.lit_names.append(a, seg.lit);
                        try node.lit_children.append(a, child_idx);
                        node_idx = child_idx;
                    }
                },
                .param => {
                    var node = &self.nodes.items[node_idx];
                    if (node.param_child) |child_idx| {
                        node_idx = child_idx;
                    } else {
                        const child_idx = try self.newNode(a);
                        node = &self.nodes.items[node_idx];
                        node.param_child = child_idx;
                        node_idx = child_idx;
                    }
                },
                .glob => {
                    setMin(&self.nodes.items[node_idx].glob_route, route.route_index);
                    return;
                },
            }
        }
        setMin(&self.nodes.items[node_idx].end_route, route.route_index);
    }
};

const PatternParamsEntry = struct {
    param_count: u32,
    next: u32,
};

const PatternParamsGlobEntry = struct {
    param_count: u32,
    route_index: u32,
};

const LiteLiteralEntry = struct {
    key: []const u8,
    hash: u64,
    child: u32,
};

const LiteLiteralMap = struct {
    entries: []LiteLiteralEntry = &.{},
    slots: []u32 = &.{}, // 0 = empty, else entry_index + 1
    mask: u64 = 0,

    fn init(a: Allocator, names: []const []const u8, children: []const u32) !LiteLiteralMap {
        var map: LiteLiteralMap = .{};
        if (names.len == 0) return map;

        map.entries = try a.alloc(LiteLiteralEntry, names.len);
        for (names, children, 0..) |name, child, i| {
            map.entries[i] = .{
                .key = name,
                .hash = util.fnv1a64(name),
                .child = child,
            };
        }

        const cap = nextPow2AtLeastRuntime(names.len * 2 + 1, 8);
        map.slots = try a.alloc(u32, cap);
        @memset(map.slots, 0);
        map.mask = @intCast(cap - 1);

        for (map.entries, 0..) |entry, i| {
            var pos: u64 = entry.hash & map.mask;
            while (true) : (pos = (pos + 1) & map.mask) {
                const slot_idx: usize = @intCast(pos);
                if (map.slots[slot_idx] == 0) {
                    map.slots[slot_idx] = @intCast(i + 1);
                    break;
                }
            }
        }

        return map;
    }

    fn get(self: *const LiteLiteralMap, key: []const u8, hash: u64) ?u32 {
        if (self.entries.len == 0) return null;
        var pos: u64 = hash & self.mask;
        var probe: usize = 0;
        while (probe < self.slots.len) : (probe += 1) {
            const slot = self.slots[@intCast(pos)];
            if (slot == 0) return null;
            const entry = self.entries[slot - 1];
            if (entry.hash == hash and std.mem.eql(u8, entry.key, key)) return entry.child;
            pos = (pos + 1) & self.mask;
        }
        return null;
    }
};

const PatternNode = struct {
    end_route: ?u32 = null,
    glob_route: ?u32 = null,
    params: []PatternParamsEntry = &.{},
    params_glob: []PatternParamsGlobEntry = &.{},
    literals: LiteLiteralMap = .{},
};

const PatternBucket = struct {
    nodes: std.ArrayListUnmanaged(PatternNode) = .empty,

    fn init(a: Allocator, routes: []Route, method: Method) !PatternBucket {
        var temp = try TempPatternBucket.init(a);
        for (routes) |route| {
            if (route.method == method and route.exact_path == null) {
                try temp.insertRoute(a, route);
            }
        }

        var bucket: PatternBucket = .{};
        _ = try bucket.compileNode(a, &temp, 0);
        return bucket;
    }

    fn compileNode(self: *PatternBucket, a: Allocator, temp: *const TempPatternBucket, temp_idx: u32) !u32 {
        const tnode = &temp.nodes.items[temp_idx];
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(a, .{
            .end_route = tnode.end_route,
            .glob_route = tnode.glob_route,
        });

        if (tnode.param_child) |param_start| {
            var params: std.ArrayListUnmanaged(PatternParamsEntry) = .empty;
            var params_glob: std.ArrayListUnmanaged(PatternParamsGlobEntry) = .empty;

            var count: u32 = 1;
            var walk_idx = param_start;
            while (true) {
                const walk = &temp.nodes.items[walk_idx];
                const pure_param_only = walk.end_route == null and
                    walk.glob_route == null and
                    walk.lit_names.items.len == 0 and
                    walk.param_child != null;

                if (pure_param_only) {
                    count += 1;
                    walk_idx = walk.param_child.?;
                    continue;
                }

                if (walk.glob_route) |rid| {
                    try params_glob.append(a, .{ .param_count = count, .route_index = rid });
                }
                if (walk.end_route != null or walk.lit_names.items.len != 0 or walk.param_child != null) {
                    try params.append(a, .{
                        .param_count = count,
                        .next = try self.compileNode(a, temp, walk_idx),
                    });
                }
                break;
            }

            self.nodes.items[idx].params = try params.toOwnedSlice(a);
            self.nodes.items[idx].params_glob = try params_glob.toOwnedSlice(a);
        }

        if (tnode.lit_names.items.len != 0) {
            const child_indices = try a.alloc(u32, tnode.lit_names.items.len);
            for (tnode.lit_names.items, 0..) |_, i| {
                child_indices[i] = try self.compileNode(a, temp, tnode.lit_children.items[i]);
            }
            self.nodes.items[idx].literals = try LiteLiteralMap.init(a, tnode.lit_names.items, child_indices);
        }

        return idx;
    }
};

const HybridBucket = struct {
    exact_entries: []ExactPathEntry = &.{},
    exact_table: FlatTable = .{},
    pattern: PatternBucket = .{},
};

const RadixHashRouter = struct {
    buckets: [method_count]HybridBucket,

    fn init(a: Allocator, routes: []Route) !RadixHashRouter {
        var exact_counts: [method_count]usize = .{0} ** method_count;

        for (routes) |r| {
            const mi = @intFromEnum(r.method);
            if (r.exact_path != null) exact_counts[mi] += 1;
        }

        var buckets: [method_count]HybridBucket = undefined;
        for (0..method_count) |mi| {
            buckets[mi] = .{
                .exact_entries = try a.alloc(ExactPathEntry, exact_counts[mi]),
                .pattern = try PatternBucket.init(a, routes, @enumFromInt(mi)),
            };
        }

        var exact_writes: [method_count]usize = .{0} ** method_count;

        for (routes) |r| {
            const mi = @intFromEnum(r.method);
            if (r.exact_path) |path| {
                const w = exact_writes[mi];
                buckets[mi].exact_entries[w] = .{
                    .path = path,
                    .hash = util.fnv1a64(path),
                    .route_index = r.route_index,
                };
                exact_writes[mi] = w + 1;
            }
        }

        for (0..method_count) |mi| {
            var bucket = &buckets[mi];

            bucket.exact_table = try FlatTable.init(a, bucket.exact_entries.len);
            for (bucket.exact_entries, 0..) |entry, i| {
                bucket.exact_table.insert(entry.hash, @intCast(i));
            }
        }

        return .{
            .buckets = buckets,
        };
    }

    fn match(self: *const RadixHashRouter, method_token: []const u8, path: []const u8) ?u32 {
        const m = parseMethod(method_token) orelse return null;
        if (m == .HEAD) {
            if (self.matchInBucket(.HEAD, path)) |rid| return rid;
            return self.matchInBucket(.GET, path);
        }
        return self.matchInBucket(m, path);
    }

    fn matchInBucket(self: *const RadixHashRouter, method: Method, path: []const u8) ?u32 {
        const bucket = &self.buckets[@intFromEnum(method)];
        if (findExactPathRaw(bucket, path)) |rid| return rid;
        const decoded = decodePath(path) orelse return null;
        return matchPatternBucket(&bucket.pattern, &decoded, 0, 0);
    }

    fn debugMatch(self: *const RadixHashRouter, method_token: []const u8, path: []const u8) void {
        const method = parseMethod(method_token) orelse return;
        const decoded = decodePath(path) orelse return;
        debugPatternBucket(&self.buckets[@intFromEnum(method)].pattern, &decoded, 0, 0, 0);
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

fn minRoute(best: ?u32, candidate: ?u32) ?u32 {
    if (candidate == null) return best;
    if (best == null or candidate.? < best.?) return candidate;
    return best;
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

fn decodePath(path: []const u8) ?DecodedPath {
    if (path.len == 0 or path[0] != '/') return null;

    var decoded: DecodedPath = .{
        .path = path,
        .path_hash = 0,
        .seg_count = 0,
        .segs = undefined,
        .seg_hashes = undefined,
    };

    var path_hash: u64 = 0xcbf29ce484222325;
    if (path.len == 1) {
        for (path) |b| {
            path_hash ^= b;
            path_hash *%= 0x100000001b3;
        }
        decoded.path_hash = path_hash;
        return decoded;
    }

    var pos: usize = 1;
    while (pos < path.len) {
        if (decoded.seg_count == max_path_segments) return null;

        const slash = std.mem.indexOfScalarPos(u8, path, pos, '/') orelse path.len;
        const part = path[pos..slash];
        if (part.len == 0) return null;
        for (path[pos - 1 .. slash]) |b| {
            path_hash ^= b;
            path_hash *%= 0x100000001b3;
        }

        const idx = decoded.seg_count;
        const part_hash = util.fnv1a64(part);
        decoded.segs[idx] = part;
        decoded.seg_hashes[idx] = part_hash;
        decoded.seg_count += 1;

        if (slash == path.len) break;
        if (slash + 1 == path.len) return null;
        pos = slash + 1;
    }

    decoded.path_hash = path_hash;
    return decoded;
}

fn findExactPath(bucket: *const HybridBucket, decoded: *const DecodedPath) ?u32 {
    if (bucket.exact_entries.len == 0) return null;

    const path_hash = decoded.path_hash;
    var pos: u64 = path_hash & bucket.exact_table.mask;
    var probe: usize = 0;
    while (probe < bucket.exact_table.slots.len) : (probe += 1) {
        const slot = bucket.exact_table.slots[@intCast(pos)];
        if (slot == 0) return null;
        const entry = bucket.exact_entries[slot - 1];
        if (entry.hash == path_hash and std.mem.eql(u8, entry.path, decoded.path)) return entry.route_index;
        pos = (pos + 1) & bucket.exact_table.mask;
    }
    return null;
}

fn findExactPathRaw(bucket: *const HybridBucket, path: []const u8) ?u32 {
    if (bucket.exact_entries.len == 0) return null;

    const path_hash = util.fnv1a64(path);
    var pos: u64 = path_hash & bucket.exact_table.mask;
    var probe: usize = 0;
    while (probe < bucket.exact_table.slots.len) : (probe += 1) {
        const slot = bucket.exact_table.slots[@intCast(pos)];
        if (slot == 0) return null;
        const entry = bucket.exact_entries[slot - 1];
        if (entry.hash == path_hash and std.mem.eql(u8, entry.path, path)) return entry.route_index;
        pos = (pos + 1) & bucket.exact_table.mask;
    }
    return null;
}

fn matchPatternBucket(bucket: *const PatternBucket, decoded: *const DecodedPath, node_idx: u32, seg_idx: usize) ?u32 {
    const node = &bucket.nodes.items[node_idx];
    var best: ?u32 = null;

    if (seg_idx == decoded.seg_count) {
        best = minRoute(best, node.end_route);
        best = minRoute(best, node.glob_route);
    } else {
        best = minRoute(best, node.glob_route);

        if (node.literals.get(decoded.segs[seg_idx], decoded.seg_hashes[seg_idx])) |child_idx| {
            best = minRoute(best, matchPatternBucket(bucket, decoded, child_idx, seg_idx + 1));
        }

        for (node.params_glob) |entry| {
            if (seg_idx + entry.param_count <= decoded.seg_count) {
                best = minRoute(best, entry.route_index);
            }
        }

        for (node.params) |entry| {
            if (seg_idx + entry.param_count <= decoded.seg_count) {
                best = minRoute(best, matchPatternBucket(bucket, decoded, entry.next, seg_idx + entry.param_count));
            }
        }
    }

    return best;
}

fn debugPatternBucket(bucket: *const PatternBucket, decoded: *const DecodedPath, node_idx: u32, seg_idx: usize, depth: usize) void {
    const node = &bucket.nodes.items[node_idx];
    std.debug.print(
        "{s}node={d} seg_idx={d} end={any} glob={any} params={d} params_glob={d}\n",
        .{ indent(depth), node_idx, seg_idx, node.end_route, node.glob_route, node.params.len, node.params_glob.len },
    );
    if (seg_idx < decoded.seg_count) {
        std.debug.print("{s}seg={s}\n", .{ indent(depth), decoded.segs[seg_idx] });
        if (node.literals.get(decoded.segs[seg_idx], decoded.seg_hashes[seg_idx])) |child_idx| {
            std.debug.print("{s}literal -> {d}\n", .{ indent(depth), child_idx });
            debugPatternBucket(bucket, decoded, child_idx, seg_idx + 1, depth + 1);
        }
        for (node.params_glob) |entry| {
            std.debug.print("{s}params_glob count={d} route={d}\n", .{ indent(depth), entry.param_count, entry.route_index });
        }
        for (node.params) |entry| {
            std.debug.print("{s}params count={d} next={d}\n", .{ indent(depth), entry.param_count, entry.next });
            if (seg_idx + entry.param_count <= decoded.seg_count) {
                debugPatternBucket(bucket, decoded, entry.next, seg_idx + entry.param_count, depth + 1);
            }
        }
    }
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

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    if (rc != 0) unreachable;
    return (@as(u64, @intCast(ts.sec)) * @as(u64, std.time.ns_per_s)) + @as(u64, @intCast(ts.nsec));
}

fn buildRoutesAndLookups(a: Allocator, n: usize) !struct { routes: []Route, lookups: []Lookup } {
    const routes = try a.alloc(Route, n);
    const hit_lookups = try a.alloc(Lookup, n);
    const miss_count = @max(1, (n * 15 + 99) / 100);
    const lookups = try a.alloc(Lookup, n + miss_count);

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
        hit_lookups[i] = .{
            .method = methodToken(m),
            .path = concrete_path,
        };
    }

    for (0..lookups.len) |i| {
        if (i % 20 < 17) {
            lookups[i] = hit_lookups[i % hit_lookups.len];
            continue;
        }

        const miss_idx = i - (i * 17 / 20);
        const miss_method: Method = switch (miss_idx % 7) {
            0 => .GET,
            1 => .POST,
            2 => .PUT,
            3 => .DELETE,
            4 => .PATCH,
            5 => .OPTIONS,
            else => .HEAD,
        };
        const miss_path = try std.fmt.allocPrint(a, "/missing/{d}/x/{d}", .{ n + miss_idx, (miss_idx % 997) + 11 });
        lookups[i] = .{
            .method = methodToken(miss_method),
            .path = miss_path,
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
        const expected = current.match(l.method, l.path);
        const got_hash = hash.match(l.method, l.path);
        const got_radix = radix.match(l.method, l.path);

        if (got_hash != expected or got_radix != expected) {
            std.debug.print(
                "router mismatch at lookup {d}: {s} {s} -> current={any} hash={any} radix={any}\n",
                .{ i, l.method, l.path, expected, got_hash, got_radix },
            );
            radix.debugMatch(l.method, l.path);
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

    try runCase(a, 50, "50");
    try runCase(a, 500, "0.5k");
    try runCase(a, 5_000, "5k");
    try runCase(a, 50_000, "50k");
}
