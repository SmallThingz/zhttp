const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const parse = @import("../parse.zig");
const router = @import("../router.zig");
const urldecode = @import("../urldecode.zig");
const util = @import("util.zig");

const Io = std.Io;

fn normalizeMount(comptime m: []const u8) []const u8 {
    if (m.len == 0 or m[0] != '/') @compileError("Static.mount must start with '/'");
    if (m.len == 1) return "/";
    if (m[m.len - 1] == '/') return m[0 .. m.len - 1];
    return m;
}

fn isSafeRelative(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        if (std.mem.indexOfScalar(u8, seg, '\\') != null) return false;
        if (std.mem.indexOfScalar(u8, seg, 0) != null) return false;
    }
    return true;
}

fn contentTypeFor(path: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const ext = path[dot + 1 ..];
    if (ext.len == 0) return null;

    const c0 = std.ascii.toLower(ext[0]);
    return switch (ext.len) {
        2 => switch (c0) {
            'j' => if (std.ascii.toLower(ext[1]) == 's') "application/javascript; charset=utf-8" else null,
            else => null,
        },
        3 => switch (c0) {
            'c' => if (std.ascii.toLower(ext[1]) == 's' and std.ascii.toLower(ext[2]) == 's') "text/css; charset=utf-8" else null,
            't' => if (std.ascii.toLower(ext[1]) == 'x' and std.ascii.toLower(ext[2]) == 't') "text/plain; charset=utf-8" else null,
            's' => if (std.ascii.toLower(ext[1]) == 'v' and std.ascii.toLower(ext[2]) == 'g') "image/svg+xml" else null,
            'p' => if (std.ascii.toLower(ext[1]) == 'n' and std.ascii.toLower(ext[2]) == 'g') "image/png" else null,
            'j' => if (std.ascii.toLower(ext[1]) == 'p' and std.ascii.toLower(ext[2]) == 'g') "image/jpeg" else null,
            'i' => if (std.ascii.toLower(ext[1]) == 'c' and std.ascii.toLower(ext[2]) == 'o') "image/x-icon" else null,
            else => null,
        },
        4 => switch (c0) {
            'h' => if (std.ascii.toLower(ext[1]) == 't' and std.ascii.toLower(ext[2]) == 'm' and std.ascii.toLower(ext[3]) == 'l') "text/html; charset=utf-8" else null,
            'j' => switch (std.ascii.toLower(ext[1])) {
                's' => if (std.ascii.toLower(ext[2]) == 'o' and std.ascii.toLower(ext[3]) == 'n') "application/json; charset=utf-8" else null,
                'p' => if (std.ascii.toLower(ext[2]) == 'e' and std.ascii.toLower(ext[3]) == 'g') "image/jpeg" else null,
                else => null,
            },
            'w' => switch (std.ascii.toLower(ext[1])) {
                'e' => if (std.ascii.toLower(ext[2]) == 'b' and std.ascii.toLower(ext[3]) == 'p') "image/webp" else null,
                'o' => if (std.ascii.toLower(ext[2]) == 'f' and std.ascii.toLower(ext[3]) == 'f') "font/woff" else null,
                else => null,
            },
            else => null,
        },
        5 => switch (c0) {
            'w' => if (std.ascii.toLower(ext[1]) == 'o' and std.ascii.toLower(ext[2]) == 'f' and
                std.ascii.toLower(ext[3]) == 'f' and std.ascii.toLower(ext[4]) == '2') "font/woff2" else null,
            else => null,
        },
        else => null,
    };
}

fn etagFor(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const h = std.hash.Wyhash.hash(0, body);
    var tmp: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&tmp, "{x:0>16}", .{h}) catch unreachable;
    const out = try allocator.alloc(u8, 18);
    out[0] = '"';
    @memcpy(out[1..17], hex);
    out[17] = '"';
    return out;
}

fn etagMatches(if_none_match: []const u8, tag: []const u8) bool {
    const trimmed = std.mem.trim(u8, if_none_match, " \t");
    if (std.mem.eql(u8, trimmed, "*")) return true;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, t, tag)) return true;
        if (t.len > 2 and t[0] == 'W' and t[1] == '/' and std.mem.eql(u8, t[2..], tag)) return true;
    }
    return false;
}

fn allocHeaders(allocator: std.mem.Allocator, src: []const Header) ![]const Header {
    if (src.len == 0) return &.{};
    const out = try allocator.alloc(Header, src.len);
    @memcpy(out, src);
    return out;
}

/// Filesystem watch options for `Static` cache invalidation.
pub const StaticWatchOptions = struct {
    /// Enables filesystem watch checks for cached files.
    ///
    /// When enabled, cache entries are validated against disk and refreshed on change.
    enabled: bool = true,
    /// Minimum interval between on-disk validation checks per cached file.
    ///
    /// `0` means check on every cache hit.
    poll_interval_ms: u32 = 250,
};

/// Configuration for `Static`.
pub const StaticOptions = struct {
    /// Directory root to serve files from.
    ///
    /// May be absolute or relative to current working directory.
    dir: []const u8,
    /// URL mount prefix for static files (must start with `/`).
    ///
    /// `/` serves from root; `/assets` serves under `/assets/*`.
    mount: []const u8 = "/",
    /// Whether this middleware should auto-register GET/HEAD routes for static serving.
    ///
    /// Disable when you want to call `serve` logic via custom routes only.
    register_routes: bool = true,
    /// Optional `cache-control` header value to include on served files.
    cache_control: ?[]const u8 = null,
    /// Optional index file name for directory requests (`/foo/` -> `/foo/{index}`).
    ///
    /// Set null to disable directory index fallback.
    index: ?[]const u8 = "index.html",
    /// Enables ETag generation and `If-None-Match` handling for static files.
    etag: bool = true,
    /// Hard upper limit for served file size in bytes.
    ///
    /// Files above this limit return `413 payload too large`.
    max_bytes: usize = std.math.maxInt(usize),
    /// Enables in-memory file caching for static responses.
    ///
    /// Cached entries store file bytes and optional ETag values.
    in_memory_cache: bool = true,
    /// Filesystem watch configuration for cache invalidation.
    ///
    /// Enabled by default. This only affects behavior when `in_memory_cache = true`.
    fs_watch: StaticWatchOptions = .{},
};

/// Serves static files from disk with optional content-type, cache-control and ETag support.
///
/// Use this middleware to host assets/docs without writing dedicated handlers.
pub fn Static(comptime opts: StaticOptions) type {
    const dir_path: []const u8 = opts.dir;
    if (dir_path.len == 0) @compileError("Static.dir must be non-empty");

    const mount = normalizeMount(opts.mount);
    const register_routes_opt = opts.register_routes;
    const cache_control: ?[]const u8 = opts.cache_control;
    const index: ?[]const u8 = opts.index;
    const etag_enabled: bool = opts.etag;
    const max_bytes: usize = opts.max_bytes;
    const cache_enabled: bool = opts.in_memory_cache;
    const watch_opts: StaticWatchOptions = opts.fs_watch;
    const watch_enabled: bool = cache_enabled and watch_opts.enabled;
    const watch_interval_ns: i128 = @as(i128, @intCast(watch_opts.poll_interval_ms)) * std.time.ns_per_ms;

    const pattern = if (std.mem.eql(u8, mount, "/")) "/*" else mount ++ "/*";
    const StaticHeaders = if (etag_enabled) struct { if_none_match: parse.Optional(parse.String) } else struct {};

    return struct {
        const Self = @This();
        const CacheEntry = struct {
            body: []u8,
            etag: ?[]u8,
            content_type: ?[]const u8,
            size: usize,
            mtime_ns: i96,
            next_watch_check_ns: i128 = 0,
        };
        const CacheMap = std.StringHashMapUnmanaged(CacheEntry);
        const CacheState = struct {
            mutex: std.Thread.Mutex = .{},
            map: CacheMap = .empty,
        };
        var cache_state: CacheState = .{};

        pub const Info = MiddlewareInfo{
            .name = "static",
            .header = if (etag_enabled) StaticHeaders else null,
        };
        pub const register_routes = register_routes_opt;
        pub const Routes = .{
            router.get(pattern, handler, .{ .headers = StaticHeaders }),
            router.head(pattern, handler, .{ .headers = StaticHeaders }),
        };

        /// Handles a middleware invocation for the current request context.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            return rctx.next(req);
        }

        fn handler(req: anytype) !Res {
            return serve(req);
        }

        fn nowNs() i128 {
            return std.time.nanoTimestamp();
        }

        fn openBaseDir(io: Io) !Io.Dir {
            return if (Io.Dir.path.isAbsolute(dir_path))
                Io.Dir.openDirAbsolute(io, dir_path, .{})
            else
                Io.Dir.cwd().openDir(io, dir_path, .{});
        }

        fn freeRemoved(kv: CacheMap.KV) void {
            const cache_a = std.heap.page_allocator;
            cache_a.free(kv.key);
            cache_a.free(kv.value.body);
            if (kv.value.etag) |tag| cache_a.free(tag);
        }

        fn cacheInsert(
            file_rel: []const u8,
            body: []const u8,
            etag: ?[]const u8,
            content_type: ?[]const u8,
            size: usize,
            mtime_ns: i96,
        ) void {
            if (!cache_enabled) return;

            const cache_a = std.heap.page_allocator;
            const key_copy = cache_a.dupe(u8, file_rel) catch return;
            errdefer cache_a.free(key_copy);

            const body_copy = cache_a.dupe(u8, body) catch return;
            errdefer cache_a.free(body_copy);

            const tag_copy = if (etag) |tag| cache_a.dupe(u8, tag) catch return else null;
            errdefer if (tag_copy) |tag| cache_a.free(tag);

            cache_state.mutex.lock();
            defer cache_state.mutex.unlock();

            if (cache_state.map.fetchRemove(file_rel)) |old| {
                freeRemoved(old);
            }

            cache_state.map.put(cache_a, key_copy, .{
                .body = body_copy,
                .etag = tag_copy,
                .content_type = content_type,
                .size = size,
                .mtime_ns = mtime_ns,
                .next_watch_check_ns = if (watch_interval_ns == 0) 0 else nowNs() + watch_interval_ns,
            }) catch {
                cache_a.free(key_copy);
                cache_a.free(body_copy);
                if (tag_copy) |tag| cache_a.free(tag);
            };
        }

        fn cacheEntryFresh(io: Io, file_rel: []const u8, entry: CacheEntry) bool {
            var base_dir = openBaseDir(io) catch return false;
            defer base_dir.close(io);

            const st = base_dir.statFile(io, file_rel, .{}) catch return false;
            if (st.kind != .file) return false;

            const on_disk_size = std.math.cast(usize, st.size) orelse return false;
            if (on_disk_size > max_bytes) return false;
            if (on_disk_size != entry.size) return false;
            return st.mtime.nanoseconds == entry.mtime_ns;
        }

        fn serveFromCache(req: anytype, file_rel: []const u8) !?Res {
            if (!cache_enabled) return null;

            cache_state.mutex.lock();
            defer cache_state.mutex.unlock();

            const entry = cache_state.map.getPtr(file_rel) orelse return null;

            if (watch_enabled) {
                const now = nowNs();
                if (watch_interval_ns == 0 or now >= entry.next_watch_check_ns) {
                    entry.next_watch_check_ns = now + watch_interval_ns;
                    if (!cacheEntryFresh(req.io(), file_rel, entry.*)) {
                        if (cache_state.map.fetchRemove(file_rel)) |old| {
                            freeRemoved(old);
                        }
                        return null;
                    }
                }
            }

            return buildResponse(req, entry.body, entry.content_type, entry.etag);
        }

        fn buildResponse(req: anytype, body: []const u8, content_type: ?[]const u8, tag: ?[]const u8) !Res {
            const a = req.allocator();
            var headers_buf: [3]Header = undefined;
            var hcount: usize = 0;

            if (content_type) |ct| {
                headers_buf[hcount] = .{ .name = "content-type", .value = ct };
                hcount += 1;
            }
            if (cache_control) |cc| {
                headers_buf[hcount] = .{ .name = "cache-control", .value = cc };
                hcount += 1;
            }
            if (tag) |t| {
                headers_buf[hcount] = .{ .name = "etag", .value = t };
                hcount += 1;
                if (etag_enabled) {
                    if (req.header(.if_none_match)) |hdr| {
                        if (etagMatches(hdr, t)) {
                            const headers_304 = try allocHeaders(a, headers_buf[0..hcount]);
                            return .{ .status = .not_modified, .headers = headers_304, .body = "" };
                        }
                    }
                }
            }

            const headers = try allocHeaders(a, headers_buf[0..hcount]);
            return .{ .status = .ok, .headers = headers, .body = body };
        }

        fn serve(req: anytype) !Res {
            var rel = req.rawPath();
            if (!std.mem.startsWith(u8, rel, mount)) return Res.text(404, "not found");
            rel = rel[mount.len..];
            if (rel.len != 0 and rel[0] == '/') rel = rel[1..];

            const a = req.allocator();
            const rel_buf = try a.dupe(u8, rel);
            const decoded = urldecode.decodeInPlace(rel_buf, .path_param) catch return Res.text(400, "bad request");
            var file_rel = decoded;

            if (file_rel.len == 0 or file_rel[file_rel.len - 1] == '/') {
                const idx = index orelse return Res.text(404, "not found");
                if (file_rel.len == 0) {
                    file_rel = try a.dupe(u8, idx);
                } else {
                    const joined = try std.fmt.allocPrint(a, "{s}{s}", .{ file_rel, idx });
                    file_rel = joined;
                }
            }

            if (!isSafeRelative(file_rel)) return Res.text(404, "not found");

            if (try serveFromCache(req, file_rel)) |res| return res;

            var base_dir = try openBaseDir(req.io());
            defer base_dir.close(req.io());

            var file = base_dir.openFile(req.io(), file_rel, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return Res.text(404, "not found"),
                error.AccessDenied, error.PermissionDenied => return Res.text(403, "forbidden"),
                else => return err,
            };
            defer file.close(req.io());

            const st = file.stat(req.io()) catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied => return Res.text(403, "forbidden"),
                else => return err,
            };
            if (st.kind != .file) return Res.text(404, "not found");

            const size = std.math.cast(usize, st.size) orelse return Res.text(413, "payload too large");
            if (size > max_bytes) return Res.text(413, "payload too large");

            const body = try a.alloc(u8, size);
            var read_buf: [8 * 1024]u8 = undefined;
            var fr = Io.File.Reader.init(file, req.io(), read_buf[0..]);
            try fr.interface.readSliceAll(body);

            const content_type = contentTypeFor(file_rel);
            const tag = if (etag_enabled) try etagFor(a, body) else null;

            cacheInsert(file_rel, body, tag, content_type, size, st.mtime.nanoseconds);
            return buildResponse(req, body, content_type, tag);
        }
    };
}

test "static: normalize mount and patterns" {
    const S = Static(.{ .dir = "public", .mount = "/static/" });
    try std.testing.expect(std.mem.eql(u8, S.Routes[0].pattern, "/static/*"));
}

fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn writeTestFile(path: []const u8, content: []const u8) !void {
    try Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = content,
    });
}

test "static: serves file and index, blocks traversal" {
    const S = Static(.{ .dir = "testdata/static", .mount = "/static" });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { if_none_match: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const gpa = std.testing.allocator;

    {
        const path_buf = "/static/hello.txt".*;
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
        const res = try S.Routes[0].handler(&reqv);
        try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("hello\n", res.body);
        try std.testing.expect(headerValue(res.headers, "content-type") != null);
    }

    {
        const path_buf = "/static/".*;
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
        const res = try S.Routes[0].handler(&reqv);
        try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("index\n", res.body);
    }

    {
        const path_buf = "/static/../secret.txt".*;
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
        const res = try S.Routes[0].handler(&reqv);
        try std.testing.expectEqual(@as(u16, 404), @intFromEnum(res.status));
    }
}

test "static: etag returns 304 on match" {
    const S = Static(.{ .dir = "testdata/static", .mount = "/static" });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { if_none_match: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    const gpa = std.testing.allocator;
    const path_buf = "/static/hello.txt".*;
    const query_buf: [0]u8 = .{};

    {
        const line: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
        defer reqv.deinit(gpa);
        const res = try S.Routes[0].handler(&reqv);
        const tag = headerValue(res.headers, "etag") orelse return error.TestExpectedEqual;
        const header_line = try std.fmt.allocPrint(gpa, "If-None-Match: {s}\r\n\r\n", .{tag});
        defer gpa.free(header_line);

        const line2: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx2: MwCtx = .{};
        var reqv2 = ReqT.init(gpa, std.testing.io, line2, mw_ctx2);
        defer reqv2.deinit(gpa);
        var r = std.Io.Reader.fixed(header_line);
        try reqv2.parseHeaders(gpa, &r, 1024);
        const res2 = try S.Routes[0].handler(&reqv2);
        try std.testing.expectEqual(@as(u16, 304), @intFromEnum(res2.status));
        try std.testing.expectEqualStrings("", res2.body);
    }
}

test "static: in-memory cache serves stale bytes when fs watch is disabled" {
    const static_dir = ".zig-cache/tmp/zhttp-static-watch-disabled";
    const file_rel = "watch.txt";
    const file_path = static_dir ++ "/" ++ file_rel;
    const S = Static(.{
        .dir = static_dir,
        .mount = "/static",
        .fs_watch = .{ .enabled = false },
    });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { if_none_match: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    var cwd = Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, static_dir);
    defer cwd.deleteTree(std.testing.io, static_dir) catch {};
    try writeTestFile(file_path, "v1\n");

    const gpa = std.testing.allocator;
    const path_buf = "/static/watch.txt".*;
    const query_buf: [0]u8 = .{};

    {
        const line: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
        defer reqv.deinit(gpa);
        const res = try S.Routes[0].handler(&reqv);
        try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("v1\n", res.body);
    }

    try writeTestFile(file_path, "v2\n");

    {
        const line: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
        defer reqv.deinit(gpa);
        const res = try S.Routes[0].handler(&reqv);
        try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("v1\n", res.body);
    }
}

test "static: in-memory cache refreshes when fs watch is enabled" {
    const static_dir = ".zig-cache/tmp/zhttp-static-watch-enabled";
    const file_rel = "watch.txt";
    const file_path = static_dir ++ "/" ++ file_rel;
    const S = Static(.{
        .dir = static_dir,
        .mount = "/static",
        .fs_watch = .{
            .enabled = true,
            .poll_interval_ms = 0,
        },
    });
    const MwCtx = struct {};
    const ReqT = @import("../request.zig").Request(
        struct { if_none_match: parse.Optional(parse.String) },
        struct {},
        &.{},
        MwCtx,
    );

    var cwd = Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, static_dir);
    defer cwd.deleteTree(std.testing.io, static_dir) catch {};
    try writeTestFile(file_path, "v1\n");

    const gpa = std.testing.allocator;
    const path_buf = "/static/watch.txt".*;
    const query_buf: [0]u8 = .{};

    {
        const line: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
        defer reqv.deinit(gpa);
        const res = try S.Routes[0].handler(&reqv);
        try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("v1\n", res.body);
    }

    try writeTestFile(file_path, "v2\n");

    {
        const line: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
        defer reqv.deinit(gpa);
        const res = try S.Routes[0].handler(&reqv);
        try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("v2\n", res.body);
    }
}
