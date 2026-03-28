const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
const MiddlewareInfo = @import("../middleware.zig").MiddlewareInfo;
const ReqCtx = @import("../req_ctx.zig").ReqCtx;
const parse = @import("../parse.zig");
const request = @import("../request.zig");
const route_decl = @import("../route_decl.zig");
const router = @import("../router.zig");
const test_helpers = @import("test_helpers.zig");
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

pub fn contentTypeFor(path: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const ext = path[dot + 1 ..];
    if (ext.len == 0) return null;

    const c0 = std.ascii.toLower(ext[0]);
    return switch (ext.len) {
        2 => switch (c0) {
            'j' => if (std.ascii.toLower(ext[1]) == 's') "application/javascript; charset=utf-8" else null,
            'm' => if (std.ascii.toLower(ext[1]) == 'd') "text/markdown; charset=utf-8" else null,
            'g' => if (std.ascii.toLower(ext[1]) == 'z') "application/gzip" else null,
            else => null,
        },
        3 => switch (c0) {
            'c' => if (std.ascii.toLower(ext[1]) == 's' and std.ascii.toLower(ext[2]) == 's')
                "text/css; charset=utf-8"
            else if (std.ascii.toLower(ext[1]) == 's' and std.ascii.toLower(ext[2]) == 'v')
                "text/csv; charset=utf-8"
            else
                null,
            't' => if (std.ascii.toLower(ext[1]) == 'x' and std.ascii.toLower(ext[2]) == 't')
                "text/plain; charset=utf-8"
            else if (std.ascii.toLower(ext[1]) == 't' and std.ascii.toLower(ext[2]) == 'f')
                "font/ttf"
            else if (std.ascii.toLower(ext[1]) == 'a' and std.ascii.toLower(ext[2]) == 'r')
                "application/x-tar"
            else
                null,
            's' => if (std.ascii.toLower(ext[1]) == 'v' and std.ascii.toLower(ext[2]) == 'g') "image/svg+xml" else null,
            'p' => if (std.ascii.toLower(ext[1]) == 'n' and std.ascii.toLower(ext[2]) == 'g')
                "image/png"
            else if (std.ascii.toLower(ext[1]) == 'd' and std.ascii.toLower(ext[2]) == 'f')
                "application/pdf"
            else
                null,
            'j' => if (std.ascii.toLower(ext[1]) == 'p' and std.ascii.toLower(ext[2]) == 'g') "image/jpeg" else null,
            'i' => if (std.ascii.toLower(ext[1]) == 'c' and std.ascii.toLower(ext[2]) == 'o') "image/x-icon" else null,
            'g' => if (std.ascii.toLower(ext[1]) == 'i' and std.ascii.toLower(ext[2]) == 'f') "image/gif" else null,
            'b' => if (std.ascii.toLower(ext[1]) == 'm' and std.ascii.toLower(ext[2]) == 'p') "image/bmp" else null,
            'x' => if (std.ascii.toLower(ext[1]) == 'm' and std.ascii.toLower(ext[2]) == 'l') "application/xml; charset=utf-8" else null,
            'w' => if (std.ascii.toLower(ext[1]) == 'a' and std.ascii.toLower(ext[2]) == 'v') "audio/wav" else null,
            'o' => if (std.ascii.toLower(ext[1]) == 'g' and std.ascii.toLower(ext[2]) == 'g') "audio/ogg" else if (std.ascii.toLower(ext[1]) == 't' and std.ascii.toLower(ext[2]) == 'f') "font/otf" else null,
            'e' => if (std.ascii.toLower(ext[1]) == 'o' and std.ascii.toLower(ext[2]) == 't') "application/vnd.ms-fontobject" else null,
            'z' => if (std.ascii.toLower(ext[1]) == 'i' and std.ascii.toLower(ext[2]) == 'p') "application/zip" else null,
            'm' => if (std.ascii.toLower(ext[1]) == 'a' and std.ascii.toLower(ext[2]) == 'p')
                "application/json; charset=utf-8"
            else if (std.ascii.toLower(ext[1]) == 'p' and ext[2] == '3')
                "audio/mpeg"
            else if (std.ascii.toLower(ext[1]) == 'p' and ext[2] == '4')
                "video/mp4"
            else if (std.ascii.toLower(ext[1]) == 'j' and std.ascii.toLower(ext[2]) == 's')
                "application/javascript; charset=utf-8"
            else
                null,
            'h' => if (std.ascii.toLower(ext[1]) == 't' and std.ascii.toLower(ext[2]) == 'm') "text/html; charset=utf-8" else null,
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
                'e' => if (std.ascii.toLower(ext[2]) == 'b' and std.ascii.toLower(ext[3]) == 'p')
                    "image/webp"
                else if (std.ascii.toLower(ext[2]) == 'b' and std.ascii.toLower(ext[3]) == 'm')
                    "video/webm"
                else
                    null,
                'o' => if (std.ascii.toLower(ext[2]) == 'f' and std.ascii.toLower(ext[3]) == 'f') "font/woff" else null,
                'a' => if (std.ascii.toLower(ext[2]) == 's' and std.ascii.toLower(ext[3]) == 'm') "application/wasm" else null,
                else => null,
            },
            'a' => if (std.ascii.toLower(ext[1]) == 'v' and std.ascii.toLower(ext[2]) == 'i' and std.ascii.toLower(ext[3]) == 'f') "image/avif" else null,
            else => null,
        },
        5 => switch (c0) {
            'w' => if (std.ascii.toLower(ext[1]) == 'o' and std.ascii.toLower(ext[2]) == 'f' and
                std.ascii.toLower(ext[3]) == 'f' and std.ascii.toLower(ext[4]) == '2') "font/woff2" else null,
            else => null,
        },
        11 => switch (c0) {
            'w' => if (std.ascii.toLower(ext[1]) == 'e' and
                std.ascii.toLower(ext[2]) == 'b' and
                std.ascii.toLower(ext[3]) == 'm' and
                std.ascii.toLower(ext[4]) == 'a' and
                std.ascii.toLower(ext[5]) == 'n' and
                std.ascii.toLower(ext[6]) == 'i' and
                std.ascii.toLower(ext[7]) == 'f' and
                std.ascii.toLower(ext[8]) == 'e' and
                std.ascii.toLower(ext[9]) == 's' and
                std.ascii.toLower(ext[10]) == 't')
                "application/manifest+json; charset=utf-8"
            else
                null,
            else => null,
        },
        else => null,
    };
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
    /// `/` serves from root; `/assets` serves under `/assets/{*path}`.
    mount: []const u8 = "/",
    /// Named trailing-glob param used to resolve file path in directory mode.
    ///
    /// Example route pattern: `/{*path}` or `/static/{*path}`.
    /// If null, static middleware inspects `req.raw().path`:
    /// - exactly one path param: use that
    /// - zero or multiple params: compile error
    glob_param_name: ?[]const u8 = null,
    /// Optional middleware name used for metadata/signature identification.
    name: ?[]const u8 = null,
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
    const glob_param_name_opt = opts.glob_param_name;
    const info_name = if (opts.name) |n| n else "static";
    const cache_control: ?[]const u8 = opts.cache_control;
    const index: ?[]const u8 = opts.index;
    const etag_enabled: bool = opts.etag;
    const max_bytes: usize = opts.max_bytes;
    const cache_enabled: bool = opts.in_memory_cache;
    const watch_opts: StaticWatchOptions = opts.fs_watch;
    const watch_enabled: bool = cache_enabled and watch_opts.enabled;
    const watch_interval_ns: i96 = @as(i96, @intCast(watch_opts.poll_interval_ms)) * std.time.ns_per_ms;

    const route_glob_name = glob_param_name_opt orelse "path";
    const pattern = if (std.mem.eql(u8, mount, "/")) "/{*" ++ route_glob_name ++ "}" else mount ++ "/{*" ++ route_glob_name ++ "}";
    const StaticHeaders = if (etag_enabled) struct { if_none_match: parse.Optional(parse.String) } else struct {};

    return struct {
        const Self = @This();
        const CacheEntry = struct {
            body: []u8,
            etag: ?[]u8,
            content_type: ?[]const u8,
            size: usize,
            mtime_ns: i96,
            next_watch_check_ns: i96 = 0,
        };
        const CacheMap = std.StringHashMapUnmanaged(CacheEntry);
        const CacheState = struct {
            ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
            map: CacheMap = .empty,
        };
        const StaticContext = struct {
            cache: ?*CacheState = null,

            pub fn init(_: Io, _: std.mem.Allocator, _: route_decl.RouteDecl) !@This() {
                const cache_a = std.heap.page_allocator;
                const cache = try cache_a.create(CacheState);
                cache.* = .{};
                return .{ .cache = cache };
            }
        };

        pub const Info = MiddlewareInfo{
            .name = info_name,
            .static_context = StaticContext,
            .header = if (etag_enabled) StaticHeaders else null,
        };
        const Endpoint = struct {
            pub const Info: router.EndpointInfo = .{
                .headers = StaticHeaders,
                .middlewares = &.{Self},
            };
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
                return serve(req);
            }
        };
        const OperationRoutes = .{
            router.get(pattern, Endpoint),
            router.head(pattern, Endpoint),
        };

        pub fn operationRoutes() @TypeOf(OperationRoutes) {
            return OperationRoutes;
        }

        /// Handles a middleware invocation for the current request context.
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            return rctx.next(req);
        }

        fn resolveGlobParamName(comptime route_pattern: []const u8) []const u8 {
            comptime var total_params: usize = 0;
            comptime var glob_params: usize = 0;
            comptime var only_name: []const u8 = "";
            comptime var selected_found: bool = false;
            comptime var selected_is_glob: bool = false;

            comptime var s: usize = 1;
            inline while (s <= route_pattern.len) : (s = blk: {
                const e2 = std.mem.indexOfScalarPos(u8, route_pattern, s, '/') orelse route_pattern.len;
                break :blk e2 + 1;
            }) {
                const e = std.mem.indexOfScalarPos(u8, route_pattern, s, '/') orelse route_pattern.len;
                const seg = route_pattern[s..e];
                if (seg.len != 0 and seg[0] == '{' and seg[seg.len - 1] == '}') {
                    const inner = seg[1 .. seg.len - 1];
                    const is_glob = inner.len != 0 and inner[0] == '*';
                    const pname = if (is_glob) inner[1..] else inner;
                    if (pname.len != 0) {
                        total_params += 1;
                        if (total_params == 1) only_name = pname;
                        if (is_glob) glob_params += 1;
                        if (glob_param_name_opt) |want| {
                            if (std.mem.eql(u8, pname, want)) {
                                selected_found = true;
                                selected_is_glob = is_glob;
                            }
                        }
                    }
                }
                if (e == route_pattern.len) break;
            }

            if (glob_param_name_opt) |want| {
                if (!selected_found) {
                    @compileError("Static.glob_param_name '" ++ want ++ "' is not present in route path '" ++ route_pattern ++ "'");
                }
                if (!selected_is_glob) {
                    @compileError("Static.glob_param_name '" ++ want ++ "' must refer to a named glob segment '{*" ++ want ++ "}' in route path '" ++ route_pattern ++ "'");
                }
                return want;
            }

            if (total_params == 1) {
                if (glob_params != 1) {
                    @compileError("Static route path '" ++ route_pattern ++ "' must expose a named trailing glob '{*name}' when inferring glob param");
                }
                return only_name;
            }
            if (total_params == 0) {
                @compileError("Static route path '" ++ route_pattern ++ "' has no path params; set Static.glob_param_name or use a '{*name}' route");
            }
            @compileError("Static route path '" ++ route_pattern ++ "' has multiple path params; set Static.glob_param_name");
        }

        fn BaseReqPtrType(comptime ReqT: type) type {
            const info = @typeInfo(ReqT);
            if (info == .pointer) {
                const Child = info.pointer.child;
                if (@hasDecl(Child, "paramsConst") and @hasDecl(Child, "ParamNames")) {
                    return ReqT;
                }
                if (@hasDecl(Child, "raw")) {
                    return @TypeOf(@as(Child, undefined).raw());
                }
                @compileError("Static.serve requires a request wrapper exposing raw() or a base request pointer");
            }
            if (@hasDecl(ReqT, "raw")) {
                return @TypeOf(@as(ReqT, undefined).raw());
            }
            @compileError("Static.serve requires a request wrapper exposing raw() or a base request pointer");
        }

        fn baseReq(req: anytype) BaseReqPtrType(@TypeOf(req)) {
            const ReqT = @TypeOf(req);
            const info = @typeInfo(ReqT);
            if (info == .pointer and @hasDecl(info.pointer.child, "raw")) return req.*.raw();
            if (info != .pointer and @hasDecl(ReqT, "raw")) return req.raw();
            return req;
        }

        fn subPathFromRequest(req: anytype) []const u8 {
            const base = baseReq(req);
            const BaseReq = @TypeOf(base.*);
            const glob_name = comptime resolveGlobParamName(BaseReq.path);
            const params = base.paramsConst().*;
            const value = @field(params, glob_name).get();
            const ti = @typeInfo(@TypeOf(value));
            if (ti != .pointer or ti.pointer.size != .slice or ti.pointer.child != u8) {
                @compileError("Static glob param '" ++ glob_name ++ "' must parse to []const u8");
            }
            return value;
        }

        fn nowNs(io: Io) i96 {
            return Io.Timestamp.now(io, .awake).nanoseconds;
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

        fn freeCacheState(cache: *CacheState) void {
            const cache_a = std.heap.page_allocator;
            var it = cache.map.iterator();
            while (it.next()) |entry| {
                freeRemoved(.{
                    .key = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                });
            }
            cache.map.deinit(cache_a);
            cache_a.destroy(cache);
        }

        fn retainCache(cache: *CacheState) *CacheState {
            _ = cache.ref_count.fetchAdd(1, .acq_rel);
            return cache;
        }

        fn releaseCache(cache: *CacheState) void {
            const old = cache.ref_count.fetchSub(1, .acq_rel);
            if (old == 1) freeCacheState(cache);
        }

        fn cacheInsert(
            io: Io,
            static_ctx: *StaticContext,
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

            const cache = retainCache(static_ctx.cache orelse return);
            defer releaseCache(cache);

            if (cache.map.fetchRemove(file_rel)) |old| {
                freeRemoved(old);
            }

            cache.map.put(cache_a, key_copy, .{
                .body = body_copy,
                .etag = tag_copy,
                .content_type = content_type,
                .size = size,
                .mtime_ns = mtime_ns,
                .next_watch_check_ns = if (watch_interval_ns == 0) 0 else nowNs(io) + watch_interval_ns,
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

        fn serveFromCache(req: anytype, static_ctx: *StaticContext, file_rel: []const u8) !?Res {
            if (!cache_enabled) return null;

            const cache = retainCache(static_ctx.cache orelse return null);
            defer releaseCache(cache);

            const entry = cache.map.getPtr(file_rel) orelse return null;

            if (watch_enabled) {
                const now = nowNs(req.io());
                if (watch_interval_ns == 0 or now >= entry.next_watch_check_ns) {
                    entry.next_watch_check_ns = now + watch_interval_ns;
                    if (!cacheEntryFresh(req.io(), file_rel, entry.*)) {
                        if (cache.map.fetchRemove(file_rel)) |old| {
                            freeRemoved(old);
                        }
                        return null;
                    }
                }
            }

            return @as(?Res, try buildResponse(req, entry.body, entry.content_type, entry.etag));
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
                        if (util.matchesIfNoneMatch(hdr, t)) {
                            const headers_304 = try util.copyHeaders(a, headers_buf[0..hcount]);
                            return .{ .status = .not_modified, .headers = headers_304, .body = "" };
                        }
                    }
                }
            }

            const headers = try util.copyHeaders(a, headers_buf[0..hcount]);
            return .{ .status = .ok, .headers = headers, .body = body };
        }

        fn serve(req: anytype) !Res {
            const a = req.allocator();
            const static_ctx = req.middlewareStatic(info_name);
            var file_rel = subPathFromRequest(req);

            if (file_rel.len == 0 or file_rel[file_rel.len - 1] == '/') {
                const idx = index orelse return Res.text(404, "not found");
                if (file_rel.len == 0) {
                    file_rel = idx;
                } else {
                    const joined = try std.fmt.allocPrint(a, "{s}{s}", .{ file_rel, idx });
                    file_rel = joined;
                }
            }

            if (!isSafeRelative(file_rel)) return Res.text(404, "not found");

            if (try serveFromCache(req, static_ctx, file_rel)) |res| return res;

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
            const tag = if (etag_enabled) try util.makeEtag(a, body, false) else null;

            cacheInsert(req.io(), static_ctx, file_rel, body, tag, content_type, size, st.mtime.nanoseconds);
            return buildResponse(req, body, content_type, tag);
        }
    };
}

test "static: normalize mount and operation routes" {
    const S = Static(.{ .dir = "public", .mount = "/static/" });
    const routes = S.operationRoutes();
    const fields = @typeInfo(@TypeOf(routes)).@"struct".fields;
    try std.testing.expect(std.mem.eql(u8, @field(routes, fields[0].name).pattern, "/static/{*path}"));
}

test "static: helper functions handle edge cases" {
    try std.testing.expect(isSafeRelative("a/b/c.txt"));
    try std.testing.expect(!isSafeRelative(""));
    try std.testing.expect(!isSafeRelative("/abs/path"));
    try std.testing.expect(!isSafeRelative("a//b"));
    try std.testing.expect(!isSafeRelative("../secret"));
    try std.testing.expect(!isSafeRelative("a\\b"));

    try std.testing.expectEqualStrings("text/html; charset=utf-8", contentTypeFor("index.HTML").?);
    try std.testing.expectEqualStrings("image/jpeg", contentTypeFor("photo.JpEg").?);
    try std.testing.expect(contentTypeFor("noext") == null);

    try std.testing.expect(util.matchesIfNoneMatch("\"abc\"", "\"abc\""));
    try std.testing.expect(util.matchesIfNoneMatch("W/\"abc\"", "\"abc\""));
    try std.testing.expect(util.matchesIfNoneMatch("W/\"x\", \"abc\"", "\"abc\""));
    try std.testing.expect(util.matchesIfNoneMatch("*", "\"abc\""));
    try std.testing.expect(!util.matchesIfNoneMatch("\"x\", \"y\"", "\"abc\""));
}

fn writeTestFile(path: []const u8, content: []const u8) !void {
    try Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = content,
    });
}

fn initStaticRouteCtx(comptime S: type, allocator: std.mem.Allocator, comptime pattern: []const u8) !@import("../middleware.zig").staticContextType(.{S}) {
    const mw = @import("../middleware.zig");
    const RouteStaticCtx = mw.staticContextType(.{S});
    const Ep = struct {
        pub const Info: router.EndpointInfo = .{};
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            _ = req;
            return Res.text(200, "ok");
        }
    };
    const rd = router.get(pattern, Ep);
    return mw.initStaticContext(RouteStaticCtx, std.testing.io, allocator, rd);
}

fn testRouteDecl(comptime method: []const u8, comptime pattern: []const u8, comptime Headers: type) router.RouteDecl {
    return .{
        .method = method,
        .pattern = pattern,
        .endpoint = struct {},
        .headers = Headers,
        .query = struct {},
        .params = struct {},
        .middlewares = &.{},
        .operations = &.{},
    };
}

fn testServerType(comptime rd: router.RouteDecl, comptime RouteStaticCtx: type) type {
    return struct {
        io: Io,
        ctx: void,
        route_static_ctx: RouteStaticCtx,

        pub fn routeDecl(comptime route_index: usize) router.RouteDecl {
            if (route_index != 0) @compileError("route index out of bounds");
            return rd;
        }

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
    };
}

test "static: contentTypeFor covers common web/media types" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", contentTypeFor("index.html").?);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", contentTypeFor("index.htm").?);
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", contentTypeFor("app.mjs").?);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", contentTypeFor("app.map").?);
    try std.testing.expectEqualStrings("application/wasm", contentTypeFor("mod.wasm").?);
    try std.testing.expectEqualStrings("video/webm", contentTypeFor("clip.webm").?);
    try std.testing.expectEqualStrings("audio/mpeg", contentTypeFor("sound.mp3").?);
    try std.testing.expectEqualStrings("application/manifest+json; charset=utf-8", contentTypeFor("site.webmanifest").?);
}

test "static: serves file and index, blocks traversal" {
    const S = Static(.{ .dir = "testdata/static", .mount = "/static" });
    const RouteStaticCtx = @import("../middleware.zig").staticContextType(.{S});
    const MwCtx = struct {};
    const Rd = testRouteDecl("GET", "/static/{*path}", struct { if_none_match: parse.Optional(parse.String) });
    const TestServer = testServerType(Rd, RouteStaticCtx);
    const ReqT = request.RequestPWithPatternExt(*TestServer, 0, Rd, MwCtx);

    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const path_buf = "/static/hello.txt".*;
        const query_buf: [0]u8 = .{};
        const line: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        const mw_static = try initStaticRouteCtx(S, a, "/static/{*path}");
        var server: TestServer = .{ .io = std.testing.io, .ctx = {}, .route_static_ctx = mw_static };
        var reqv = ReqT.initWithServer(a, line, mw_ctx, &server);
        defer reqv.deinit(a);
        var rel0 = "hello.txt".*;
        try reqv.parseParams(a, &.{rel0[0..]});
        const res = try S.serve(&reqv);
        try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("hello\n", res.body);
        try std.testing.expect(test_helpers.headerValue(res.headers, "content-type") != null);
    }

    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const path_buf = "/static/".*;
        const query_buf: [0]u8 = .{};
        const line: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        const mw_static = try initStaticRouteCtx(S, a, "/static/{*path}");
        var server: TestServer = .{ .io = std.testing.io, .ctx = {}, .route_static_ctx = mw_static };
        var reqv = ReqT.initWithServer(a, line, mw_ctx, &server);
        defer reqv.deinit(a);
        try reqv.parseParams(a, &.{""});
        const res = try S.serve(&reqv);
        try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("index\n", res.body);
    }

    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const path_buf = "/static/../secret.txt".*;
        const query_buf: [0]u8 = .{};
        const line: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        const mw_static = try initStaticRouteCtx(S, a, "/static/{*path}");
        var server: TestServer = .{ .io = std.testing.io, .ctx = {}, .route_static_ctx = mw_static };
        var reqv = ReqT.initWithServer(a, line, mw_ctx, &server);
        defer reqv.deinit(a);
        var rel_bad = "../secret.txt".*;
        try reqv.parseParams(a, &.{rel_bad[0..]});
        const res = try S.serve(&reqv);
        try std.testing.expectEqual(@as(u16, 404), @intFromEnum(res.status));
    }
}

test "static: explicit glob_param_name works with multiple path params" {
    const S = Static(.{
        .dir = "testdata/static",
        .mount = "/static",
        .glob_param_name = "rest",
    });
    const RouteStaticCtx = @import("../middleware.zig").staticContextType(.{S});
    const MwCtx = struct {};
    const Rd = testRouteDecl("GET", "/x/{prefix}/{*rest}", struct { if_none_match: parse.Optional(parse.String) });
    const TestServer = testServerType(Rd, RouteStaticCtx);
    const ReqT = request.RequestPWithPatternExt(*TestServer, 0, Rd, MwCtx);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const path_buf = "/x/prefix/hello.txt".*;
    const query_buf: [0]u8 = .{};
    const line: @import("../request.zig").RequestLine = .{
        .method = "GET",
        .version = .http11,
        .path = @constCast(path_buf[0..]),
        .query = @constCast(query_buf[0..]),
    };
    const mw_ctx: MwCtx = .{};
    const mw_static = try initStaticRouteCtx(S, a, "/x/{prefix}/{*rest}");
    var server: TestServer = .{ .io = std.testing.io, .ctx = {}, .route_static_ctx = mw_static };
    var reqv = ReqT.initWithServer(a, line, mw_ctx, &server);
    defer reqv.deinit(a);
    var p0 = "prefix".*;
    var p1 = "hello.txt".*;
    try reqv.parseParams(a, &.{ p0[0..], p1[0..] });
    const res = try S.serve(&reqv);
    try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
    try std.testing.expectEqualStrings("hello\n", res.body);
}

test "static: etag returns 304 on match" {
    const S = Static(.{ .dir = "testdata/static", .mount = "/static" });
    const RouteStaticCtx = @import("../middleware.zig").staticContextType(.{S});
    const MwCtx = struct {};
    const Rd = testRouteDecl("GET", "/static/{*path}", struct { if_none_match: parse.Optional(parse.String) });
    const TestServer = testServerType(Rd, RouteStaticCtx);
    const ReqT = request.RequestPWithPatternExt(*TestServer, 0, Rd, MwCtx);

    const path_buf = "/static/hello.txt".*;
    const query_buf: [0]u8 = .{};

    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const line: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx: MwCtx = .{};
        const mw_static = try initStaticRouteCtx(S, a, "/static/{*path}");
        var server: TestServer = .{ .io = std.testing.io, .ctx = {}, .route_static_ctx = mw_static };
        var reqv = ReqT.initWithServer(a, line, mw_ctx, &server);
        defer reqv.deinit(a);
        var rel1 = "hello.txt".*;
        try reqv.parseParams(a, &.{rel1[0..]});
        const res = try S.serve(&reqv);
        const tag = test_helpers.headerValue(res.headers, "etag") orelse return error.TestExpectedEqual;
        const header_line = try std.fmt.allocPrint(a, "If-None-Match: {s}\r\n\r\n", .{tag});

        const line2: @import("../request.zig").RequestLine = .{
            .method = "GET",
            .version = .http11,
            .path = @constCast(path_buf[0..]),
            .query = @constCast(query_buf[0..]),
        };
        const mw_ctx2: MwCtx = .{};
        var server2: TestServer = .{ .io = std.testing.io, .ctx = {}, .route_static_ctx = mw_static };
        var reqv2 = ReqT.initWithServer(a, line2, mw_ctx2, &server2);
        defer reqv2.deinit(a);
        var rel6 = "hello.txt".*;
        try reqv2.parseParams(a, &.{rel6[0..]});
        var r = std.Io.Reader.fixed(header_line);
        try reqv2.parseHeaders(a, &r, 1024);
        const res2 = try S.serve(&reqv2);
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
    const RouteStaticCtx = @import("../middleware.zig").staticContextType(.{S});
    const MwCtx = struct {};
    const Rd = testRouteDecl("GET", "/static/{*path}", struct { if_none_match: parse.Optional(parse.String) });
    const TestServer = testServerType(Rd, RouteStaticCtx);
    const ReqT = request.RequestPWithPatternExt(*TestServer, 0, Rd, MwCtx);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mw_static = try initStaticRouteCtx(S, a, "/static/{*path}");

    var cwd = Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, static_dir);
    defer cwd.deleteTree(std.testing.io, static_dir) catch {};
    try writeTestFile(file_path, "v1\n");

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
        var server: TestServer = .{ .io = std.testing.io, .ctx = {}, .route_static_ctx = mw_static };
        var reqv = ReqT.initWithServer(a, line, mw_ctx, &server);
        defer reqv.deinit(a);
        var rel2 = "watch.txt".*;
        try reqv.parseParams(a, &.{rel2[0..]});
        const res = try S.serve(&reqv);
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
        var server: TestServer = .{ .io = std.testing.io, .ctx = {}, .route_static_ctx = mw_static };
        var reqv = ReqT.initWithServer(a, line, mw_ctx, &server);
        defer reqv.deinit(a);
        var rel3 = "watch.txt".*;
        try reqv.parseParams(a, &.{rel3[0..]});
        const res = try S.serve(&reqv);
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
    const RouteStaticCtx = @import("../middleware.zig").staticContextType(.{S});
    const MwCtx = struct {};
    const Rd = testRouteDecl("GET", "/static/{*path}", struct { if_none_match: parse.Optional(parse.String) });
    const TestServer = testServerType(Rd, RouteStaticCtx);
    const ReqT = request.RequestPWithPatternExt(*TestServer, 0, Rd, MwCtx);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mw_static = try initStaticRouteCtx(S, a, "/static/{*path}");

    var cwd = Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, static_dir);
    defer cwd.deleteTree(std.testing.io, static_dir) catch {};
    try writeTestFile(file_path, "v1\n");

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
        var server: TestServer = .{ .io = std.testing.io, .ctx = {}, .route_static_ctx = mw_static };
        var reqv = ReqT.initWithServer(a, line, mw_ctx, &server);
        defer reqv.deinit(a);
        var rel4 = "watch.txt".*;
        try reqv.parseParams(a, &.{rel4[0..]});
        const res = try S.serve(&reqv);
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
        var server: TestServer = .{ .io = std.testing.io, .ctx = {}, .route_static_ctx = mw_static };
        var reqv = ReqT.initWithServer(a, line, mw_ctx, &server);
        defer reqv.deinit(a);
        var rel5 = "watch.txt".*;
        try reqv.parseParams(a, &.{rel5[0..]});
        const res = try S.serve(&reqv);
        try std.testing.expectEqual(@as(u16, 200), @intFromEnum(res.status));
        try std.testing.expectEqualStrings("v2\n", res.body);
    }
}
