const std = @import("std");

const parse = @import("../parse.zig");
const Res = @import("../response.zig").Res;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;

comptime {
    @setEvalBranchQuota(200_000);
}

fn validateOrigins(comptime origins: []const []const u8) void {
    comptime {
        @setEvalBranchQuota(200_000);
    }
    if (origins.len == 0) {
        @compileError("Origin middleware requires at least one allowed origin");
    }

    inline for (origins, 0..) |origin, i| {
        if (origin.len == 0) @compileError("allowed origins must not be empty");
        inline for (origins[0..i]) |existing| {
            if (std.mem.eql(u8, origin, existing)) @compileError("duplicate allowed origin: " ++ origin);
        }
    }
}

pub fn DecisionTree(comptime origins: []const []const u8) type {
    comptime {
        @setEvalBranchQuota(200_000);
    }
    validateOrigins(origins);

    const count = origins.len;
    const allowed: [count][]const u8 = origins[0..count].*;
    const all_ids: [count]usize = comptime blk: {
        var out: [count]usize = undefined;
        for (0..count) |i| out[i] = i;
        break :blk out;
    };

    return struct {
        fn pack4(s: []const u8, offset: usize) u32 {
            comptime {
                @setEvalBranchQuota(200_000);
            }
            var v: u32 = 0;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const idx = offset + i;
                const b: u8 = if (idx < s.len) s[idx] else 0;
                v |= @as(u32, b) << @intCast(i * 8);
            }
            return v;
        }

        fn eqLiteral(bytes: []const u8, comptime lit: []const u8) bool {
            if (bytes.len != lit.len) return false;
            inline for (lit, 0..) |c, i| {
                if (bytes[i] != c) return false;
            }
            return true;
        }

        fn maxLenForIds(comptime ids: []const usize) usize {
            var m: usize = 0;
            for (ids) |id| {
                const len = allowed[id].len;
                if (len > m) m = len;
            }
            return m;
        }

        fn uniqueKeys(comptime ids: []const usize, comptime offset: usize) struct { keys: [ids.len]u32, len: usize } {
            comptime {
                @setEvalBranchQuota(200_000);
            }
            var out: [ids.len]u32 = undefined;
            var n: usize = 0;
            for (ids) |id| {
                const k = pack4(allowed[id], offset);
                var found = false;
                for (out[0..n]) |existing| {
                    if (existing == k) {
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

        fn filterIds(comptime ids: []const usize, comptime offset: usize, comptime key: u32) struct { ids: [ids.len]usize, len: usize } {
            comptime {
                @setEvalBranchQuota(200_000);
            }
            var out: [ids.len]usize = undefined;
            var n: usize = 0;
            for (ids) |id| {
                if (pack4(allowed[id], offset) == key) {
                    out[n] = id;
                    n += 1;
                }
            }
            return .{ .ids = out, .len = n };
        }

        fn containsImpl(comptime ids: []const usize, comptime offset: usize, origin: []const u8) bool {
            comptime {
                @setEvalBranchQuota(200_000);
            }
            if (ids.len == 0) return false;
            if (ids.len == 1) return eqLiteral(origin, allowed[ids[0]]);

            if (offset >= comptime maxLenForIds(ids)) {
                inline for (ids) |id| {
                    if (std.mem.eql(u8, origin, allowed[id])) return true;
                }
                return false;
            }

            const key = pack4(origin, offset);
            const keys = comptime uniqueKeys(ids, offset);
            inline for (keys.keys[0..keys.len]) |kcase| {
                if (key == kcase) {
                    const sub = comptime filterIds(ids, offset, kcase);
                    return containsImpl(sub.ids[0..sub.len], offset + 4, origin);
                }
            }
            return false;
        }

        pub fn contains(origin: []const u8) bool {
            if (comptime count == 1) return eqLiteral(origin, allowed[0]);
            return containsImpl(all_ids[0..], 0, origin);
        }
    };
}

pub fn HashMatcher(comptime origins: []const []const u8) type {
    comptime {
        @setEvalBranchQuota(200_000);
    }
    validateOrigins(origins);

    const count = origins.len;
    const allowed: [count][]const u8 = origins[0..count].*;
    const cap = comptime std.math.ceilPowerOfTwo(usize, @max(16, count * 2)) catch 16;
    const table = comptime blk: {
        var keys: [cap][]const u8 = undefined;
        var meta: [cap]u8 = [_]u8{0} ** cap;

        for (allowed) |origin| {
            const hash = std.hash_map.StringContext.hash(undefined, origin);
            const fp0: u8 = @intCast(hash >> 56);
            const hfp = .{
                .hash = hash,
                .fp = if (fp0 == 0) 1 else fp0,
            };
            var i: usize = @intCast(hfp.hash & (cap - 1));
            while (meta[i] != 0) : (i = (i + 1) & (cap - 1)) {}
            meta[i] = hfp.fp;
            keys[i] = origin;
        }

        break :blk .{ .keys = keys, .meta = meta };
    };

    return struct {
        fn getHFP(origin: []const u8) struct { hash: u64, fp: u8 } {
            const hash = std.hash_map.StringContext.hash(undefined, origin);
            const fp0: u8 = @intCast(hash >> 56);
            return .{
                .hash = hash,
                .fp = if (fp0 == 0) 1 else fp0,
            };
        }

        pub fn contains(origin: []const u8) bool {
            const hfp = getHFP(origin);
            var i: usize = @intCast(hfp.hash & (cap - 1));
            while (table.meta[i] != 0) : (i = (i + 1) & (cap - 1)) {
                if (table.meta[i] == hfp.fp and std.mem.eql(u8, table.keys[i], origin)) return true;
            }
            return false;
        }
    };
}

/// Configuration for `Origin`.
pub const OriginOptions = struct {
    /// Exact list of allowed `Origin` header values.
    ///
    /// Matching is byte-for-byte (scheme, host, port must match exactly).
    origins: []const []const u8,
    /// Whether requests missing an `Origin` header are allowed.
    ///
    /// Keep `false` for stricter browser-origin enforcement.
    allow_missing: bool = false,
    /// HTTP status returned when origin validation fails.
    status: u16 = 403,
    /// Response body returned when origin validation fails.
    body: []const u8 = "forbidden origin\n",
    /// Optional middleware context field name used to store allow/missing decision.
    name: ?[]const u8 = null,
};

/// Enforces an allow-list for the `Origin` request header.
///
/// Use this middleware to mitigate cross-site websocket/API abuse for browser clients.
pub fn Origin(comptime opts: OriginOptions) type {
    const origins = opts.origins;
    validateOrigins(origins);

    const allow_missing: bool = opts.allow_missing;
    const reject_status: u16 = opts.status;
    const reject_body: []const u8 = opts.body;
    const store: bool = opts.name != null;
    const Matcher = HashMatcher(origins);

    const DataT = if (store) struct {
        allowed: bool = false,
        missing: bool = false,
    } else struct {};

    const Common = struct {
        pub const info_name: []const u8 = if (store) opts.name.? else "origin";
        pub const Info = MiddlewareInfo{
            .name = info_name,
            .data = if (store) DataT else null,
            .header = struct {
                origin: parse.Optional(parse.String),
            },
        };

        pub const Data = DataT;

        fn handle(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            const origin = req.header(.origin);
            const allowed = if (origin) |value| Matcher.contains(value) else allow_missing;

            if (store) {
                const data = req.middlewareData(info_name);
                data.allowed = allowed;
                data.missing = origin == null;
            }

            if (!allowed) return Res.text(reject_status, reject_body);
            return rctx.next(req);
        }
    };

    return struct {
        pub const Info = Common.Info;
        pub const Data = Common.Data;

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            return Common.handle(rctx, req);
        }
    };
}

test "origin decision tree matches exact origins" {
    const Matcher = DecisionTree(&.{
        "https://app.example.com",
        "https://admin.example.com:8443",
        "http://localhost:3000",
    });

    try std.testing.expect(Matcher.contains("https://app.example.com"));
    try std.testing.expect(Matcher.contains("https://admin.example.com:8443"));
    try std.testing.expect(!Matcher.contains("https://app.example.com:443"));
    try std.testing.expect(!Matcher.contains("https://app.example.co"));
    try std.testing.expect(!Matcher.contains("http://localhost"));
}

test "origin hash matcher matches exact origins" {
    const Matcher = HashMatcher(&.{
        "https://app.example.com",
        "https://admin.example.com:8443",
        "http://localhost:3000",
    });

    try std.testing.expect(Matcher.contains("https://app.example.com"));
    try std.testing.expect(Matcher.contains("https://admin.example.com:8443"));
    try std.testing.expect(!Matcher.contains("https://app.example.com:443"));
    try std.testing.expect(!Matcher.contains("https://app.example.co"));
    try std.testing.expect(!Matcher.contains("http://localhost"));
}

test "origin middleware allows configured origin" {
    const Mw = Origin(.{
        .origins = &.{ "https://app.example.com", "http://localhost:3000" },
    });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {
        origin: parse.Optional(parse.String),
    }, struct {}, &.{}, MwCtx);

    const Next = struct {
        pub fn call(_: @This(), _: anytype) !Res {
            return Res.text(200, "ok");
        }
    };

    const gpa = std.testing.allocator;
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    reqv.headersMut().origin = .{
        .present = true,
        .inner = .{ .value = "https://app.example.com" },
    };

    const res = try Mw.call(Next, Next{}, &reqv);
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
}

test "origin middleware rejects missing origin by default" {
    const Mw = Origin(.{ .origins = &.{"https://app.example.com"} });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(struct {
        origin: parse.Optional(parse.String),
    }, struct {}, &.{}, MwCtx);

    const Next = struct {
        pub fn call(_: @This(), _: anytype) !Res {
            return Res.text(200, "ok");
        }
    };

    const gpa = std.testing.allocator;
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    const res = try Mw.call(Next, Next{}, &reqv);
    try std.testing.expectEqual(@as(u16, 403), @intFromEnum(res.status));
    try std.testing.expectEqualStrings("forbidden origin\n", res.body);
}

test "origin middleware can allow missing origin and store decision" {
    const Mw = Origin(.{
        .origins = &.{"https://app.example.com"},
        .allow_missing = true,
        .name = "origin",
    });
    const MwCtx = struct {
        origin: Mw.Data = .{},
    };
    const ReqT = @import("../request.zig").Request(struct {
        origin: parse.Optional(parse.String),
    }, struct {}, &.{}, MwCtx);

    const Next = struct {
        pub fn call(_: @This(), _: anytype) !Res {
            return Res.text(200, "ok");
        }
    };

    const gpa = std.testing.allocator;
    const path_buf = "/".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    const res = try Mw.call(Next, Next{}, &reqv);
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
    try std.testing.expect(reqv.mwCtxConst().origin.allowed);
    try std.testing.expect(reqv.mwCtxConst().origin.missing);
}

test "origin matcher has expected decisions for mixed probes" {
    const Matcher = DecisionTree(&.{
        "https://app.example.com",
        "https://admin.example.com",
        "https://api.example.com",
        "http://localhost:3000",
        "http://127.0.0.1:5173",
    });
    const probes = [_]struct { origin: []const u8, expected: bool }{
        .{ .origin = "https://app.example.com", .expected = true },
        .{ .origin = "https://api.example.com", .expected = true },
        .{ .origin = "https://app.example.com:443", .expected = false },
        .{ .origin = "https://evil.example.com", .expected = false },
        .{ .origin = "http://localhost:3000", .expected = true },
        .{ .origin = "http://localhost:4000", .expected = false },
    };

    for (probes) |probe| {
        try std.testing.expectEqual(probe.expected, Matcher.contains(probe.origin));
    }
}

test "origin decision tree and hash matcher agree" {
    const origins = &.{
        "https://app.example.com",
        "https://admin.example.com",
        "https://api.example.com",
        "http://localhost:3000",
        "http://127.0.0.1:5173",
    };
    const Tree = DecisionTree(origins);
    const Hash = HashMatcher(origins);
    const probes = [_][]const u8{
        "https://app.example.com",
        "https://api.example.com",
        "https://app.example.com:443",
        "https://evil.example.com",
        "http://localhost:3000",
        "http://localhost:4000",
    };

    for (probes) |probe| {
        try std.testing.expectEqual(Tree.contains(probe), Hash.contains(probe));
    }
}
