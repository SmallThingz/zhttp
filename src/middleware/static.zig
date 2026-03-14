const std = @import("std");

const Res = @import("../response.zig").Res;
const Header = @import("../response.zig").Header;
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
    if (std.ascii.eqlIgnoreCase(ext, "html")) return "text/html; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, "css")) return "text/css; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, "js")) return "application/javascript; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, "json")) return "application/json; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, "txt")) return "text/plain; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(ext, "svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(ext, "png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, "webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, "ico")) return "image/x-icon";
    if (std.ascii.eqlIgnoreCase(ext, "woff")) return "font/woff";
    if (std.ascii.eqlIgnoreCase(ext, "woff2")) return "font/woff2";
    return null;
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

pub fn Static(comptime opts: anytype) type {
    if (!@hasField(@TypeOf(opts), "dir")) @compileError("Static requires .dir");
    const dir_path: []const u8 = opts.dir;
    if (dir_path.len == 0) @compileError("Static.dir must be non-empty");

    const mount = normalizeMount(if (@hasField(@TypeOf(opts), "mount")) opts.mount else "/");
    const register_routes_opt = if (@hasField(@TypeOf(opts), "register_routes")) opts.register_routes else true;
    const cache_control: ?[]const u8 = if (@hasField(@TypeOf(opts), "cache_control")) opts.cache_control else null;
    const index: ?[]const u8 = if (@hasField(@TypeOf(opts), "index")) opts.index else "index.html";
    const etag_enabled: bool = if (@hasField(@TypeOf(opts), "etag")) opts.etag else true;
    const max_bytes: usize = if (@hasField(@TypeOf(opts), "max_bytes")) opts.max_bytes else std.math.maxInt(usize);

    const pattern = if (std.mem.eql(u8, mount, "/")) "/*" else mount ++ "/*";
    const StaticHeaders = if (etag_enabled) struct { if_none_match: parse.Optional(parse.String) } else struct {};

    return struct {
        pub const register_routes = register_routes_opt;
        pub const Routes = .{
            router.get(pattern, handler, .{ .headers = StaticHeaders }),
            router.head(pattern, handler, .{ .headers = StaticHeaders }),
        };

        pub fn call(comptime Next: type, next: Next, ctx: anytype, req: anytype) !Res {
            return next.call(ctx, req);
        }

        fn handler(req: anytype) !Res {
            return serve(req);
        }

        fn serve(req: anytype) !Res {
            var rel = req.path_raw;
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

            var base_dir = if (Io.Dir.path.isAbsolute(dir_path))
                try Io.Dir.openDirAbsolute(req.io, dir_path, .{})
            else
                try Io.Dir.cwd().openDir(req.io, dir_path, .{});
            defer base_dir.close(req.io);

            var file = base_dir.openFile(req.io, file_rel, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return Res.text(404, "not found"),
                error.AccessDenied, error.PermissionDenied => return Res.text(403, "forbidden"),
                else => return err,
            };
            defer file.close(req.io);

            const st = file.stat(req.io) catch |err| switch (err) {
                error.AccessDenied, error.PermissionDenied => return Res.text(403, "forbidden"),
                else => return err,
            };
            if (st.kind != .file) return Res.text(404, "not found");

            const size = std.math.cast(usize, st.size) orelse return Res.text(413, "payload too large");
            if (size > max_bytes) return Res.text(413, "payload too large");

            const body = try a.alloc(u8, size);
            var read_buf: [8 * 1024]u8 = undefined;
            var fr = Io.File.Reader.init(file, req.io, read_buf[0..]);
            try fr.interface.readSliceAll(body);

            var headers_buf: [3]Header = undefined;
            var hcount: usize = 0;

            if (contentTypeFor(file_rel)) |ct| {
                headers_buf[hcount] = .{ .name = "content-type", .value = ct };
                hcount += 1;
            }
            if (cache_control) |cc| {
                headers_buf[hcount] = .{ .name = "cache-control", .value = cc };
                hcount += 1;
            }

            if (etag_enabled) {
                const tag = try etagFor(a, body);
                headers_buf[hcount] = .{ .name = "etag", .value = tag };
                hcount += 1;
                if (req.header(.if_none_match)) |hdr| {
                    if (etagMatches(hdr, tag)) {
                        return .{ .status = 304, .headers = headers_buf[0..hcount], .body = "" };
                    }
                }
            }

            return .{ .status = 200, .headers = headers_buf[0..hcount], .body = body };
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
        try std.testing.expectEqual(@as(u16, 200), res.status);
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
        try std.testing.expectEqual(@as(u16, 200), res.status);
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
        try std.testing.expectEqual(@as(u16, 404), res.status);
    }
}
