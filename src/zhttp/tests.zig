const std = @import("std");

const zhttp = @import("../root.zig");

const request = @import("request.zig");
const response = @import("response.zig");
const router = @import("router.zig");
const parse = @import("parse.zig");

test "request line: borrowed parses path/query" {
    var r = std.Io.Reader.fixed("GET /a/b?x=1 HTTP/1.1\r\n");
    const line = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    try std.testing.expectEqual(zhttp.Method.GET, line.method);
    try std.testing.expectEqual(request.Version.http11, line.version);
    try std.testing.expectEqualStrings("/a/b", line.path);
    try std.testing.expectEqualStrings("x=1", line.query);
}

test "request line: owned duplicates path/query" {
    var r = std.Io.Reader.fixed("GET /hello HTTP/1.1\r\n");
    const gpa = std.testing.allocator;
    const line = try request.parseRequestLine(@constCast(&r), gpa, 8 * 1024);
    defer gpa.free(line.path);
    defer gpa.free(line.query);
    try std.testing.expectEqualStrings("/hello", line.path);
    try std.testing.expectEqualStrings("", line.query);
}

test "response: rawPartsCopy matches raw bytes" {
    const base =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n";
    const date = "Date: Wed, 24 Feb 2021 12:00:00 GMT";
    const body = "Hello, World!";
    const res = zhttp.Res.rawPartsCopy(&.{ base, date, "\r\n\r\n", body });

    var out: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(out[0..]);
    try response.write(&w, res, true, true);

    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "\r\n" ++
        "Hello, World!";
    try std.testing.expectEqualStrings(expected, out[0..w.end]);
}

test "headers: underscore field matches dash header" {
    const ReqT = request.Request(
        struct {
            content_type: parse.Optional(parse.String),
        },
        struct {},
        &.{},
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = std.Io.Reader.fixed("Content-Type: text/plain\r\n\r\n");
    try reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024);
    try std.testing.expectEqualStrings("text/plain", reqv.header(.content_type).?);
}

test "query: decode + optional parsing" {
    const ReqT = request.Request(
        struct {},
        struct {
            name: parse.Optional(parse.String),
            page: parse.Optional(parse.Int(u32)),
        },
        &.{},
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "name=alice%20bob&page=10");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    try reqv.parseQuery(gpa);
    try std.testing.expectEqualStrings("alice bob", reqv.queryParam(.name).?);
    try std.testing.expectEqual(@as(u32, 10), reqv.queryParam(.page).?);
}

test "bodyAll: content-length" {
    const ReqT = request.Request(struct {}, struct {}, &.{});

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = std.Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    try reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024);
    const body = try reqv.bodyAll(gpa, @constCast(&r), 16);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

test "bodyAll: chunked" {
    const ReqT = request.Request(struct {}, struct {}, &.{});

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = std.Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
    try reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024);
    const body = try reqv.bodyAll(gpa, @constCast(&r), 64);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

test "router: exact + param + glob" {
    const App = struct {};
    const S = router.Compiled(App, .{
        zhttp.get("/a", .{}, struct {
            fn h(_: *App, _: anytype) !zhttp.Res {
                return zhttp.Res.text(200, "a");
            }
        }.h),
        zhttp.get("/u/{id}", .{}, struct {
            fn h(_: *App, _: anytype) !zhttp.Res {
                return zhttp.Res.text(200, "u");
            }
        }.h),
        zhttp.get("/g/*", .{}, struct {
            fn h(_: *App, _: anytype) !zhttp.Res {
                return zhttp.Res.text(200, "g");
            }
        }.h),
    }, .{});

    var params: [S.MaxParams][]u8 = undefined;

    var p0 = "/a".*;
    try std.testing.expectEqual(@as(?u16, 0), S.match(.GET, p0[0..], params[0..S.MaxParams]));

    var p1 = "/u/123".*;
    try std.testing.expectEqual(@as(?u16, 1), S.match(.GET, p1[0..], params[0..S.MaxParams]));

    var p2 = "/g/anything/here".*;
    try std.testing.expectEqual(@as(?u16, 2), S.match(.GET, p2[0..], params[0..S.MaxParams]));
}

test "middleware Needs: supports 'headers: type = ...' form" {
    const Mw = struct {
        pub const Needs = struct {
            headers: type = struct {
                host: parse.Optional(parse.String),
            },
            query: type = struct {},
        };

        pub fn call(comptime Next: type, next: Next, _: void, _: anytype) !zhttp.Res {
            return next.call({}, undefined);
        }
    };

    _ = router.Compiled(void, .{
        zhttp.get("/x", .{}, struct {
            fn h(_: void, _: anytype) !zhttp.Res {
                return zhttp.Res.text(200, "x");
            }
        }.h),
    }, .{Mw});
}

test "headers: too large rejected" {
    const ReqT = request.Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = std.Io.Reader.fixed("X: 1234567890\r\n\r\n");
    try std.testing.expectError(error.HeadersTooLarge, reqv.parseHeaders(gpa, @constCast(&r), 8));
}

test "headers: duplicate Content-Length mismatch rejected" {
    const ReqT = request.Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = std.Io.Reader.fixed("Content-Length: 1\r\nContent-Length: 2\r\n\r\n");
    try std.testing.expectError(error.BadRequest, reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024));
}

test "headers: chunked + Content-Length rejected" {
    const ReqT = request.Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = std.Io.Reader.fixed("Transfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n");
    try std.testing.expectError(error.BadRequest, reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024));
}

test "headers: Connection close disables keep-alive" {
    const ReqT = request.Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = std.Io.Reader.fixed("Connection: keep-alive, Close\r\n\r\n");
    try reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024);
    try std.testing.expect(!reqv.keepAlive());
}

test "query: required missing rejected" {
    const ReqT = request.Request(
        struct {},
        struct {
            q: parse.String,
        },
        &.{},
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    try std.testing.expectError(error.MissingRequired, reqv.parseQuery(gpa));
}

test "query: invalid percent-encoding rejected" {
    const ReqT = request.Request(
        struct {},
        struct {
            name: parse.Optional(parse.String),
        },
        &.{},
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "name=%ZZ");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    try std.testing.expectError(error.InvalidPercentEncoding, reqv.parseQuery(gpa));
}

test "dispatch: pipelined request discards unread content-length body" {
    const S = router.Compiled(void, .{
        zhttp.post("/x", .{}, struct {
            fn h(_: void, _: anytype) !zhttp.Res {
                return zhttp.Res.text(200, "p");
            }
        }.h),
        zhttp.get("/x", .{}, struct {
            fn h(_: void, _: anytype) !zhttp.Res {
                return zhttp.Res.text(200, "g");
            }
        }.h),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var params: [S.MaxParams][]u8 = undefined;
    var r = std.Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Content-Length: 5\r\n" ++
            "\r\n" ++
            "hello" ++
            "GET /x HTTP/1.1\r\n" ++
            "\r\n",
    );

    const line1 = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    const rid1 = S.match(line1.method, line1.path, params[0..S.MaxParams]).?;
    const dr1 = try S.dispatch({}, a, @constCast(&r), line1, rid1, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqual(@as(u16, 200), dr1.res.status);
    try std.testing.expectEqualStrings("p", dr1.res.body);
    try std.testing.expect(dr1.keep_alive);

    const line2 = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    const rid2 = S.match(line2.method, line2.path, params[0..S.MaxParams]).?;
    const dr2 = try S.dispatch({}, a, @constCast(&r), line2, rid2, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqual(@as(u16, 200), dr2.res.status);
    try std.testing.expectEqualStrings("g", dr2.res.body);
}

test "dispatch: pipelined request discards unread chunked body" {
    const S = router.Compiled(void, .{
        zhttp.post("/x", .{}, struct {
            fn h(_: void, _: anytype) !zhttp.Res {
                return zhttp.Res.text(200, "p");
            }
        }.h),
        zhttp.get("/x", .{}, struct {
            fn h(_: void, _: anytype) !zhttp.Res {
                return zhttp.Res.text(200, "g");
            }
        }.h),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var params: [S.MaxParams][]u8 = undefined;
    var r = std.Io.Reader.fixed(
        "POST /x HTTP/1.1\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nhello\r\n0\r\n\r\n" ++
            "GET /x HTTP/1.1\r\n" ++
            "\r\n",
    );

    const line1 = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    const rid1 = S.match(line1.method, line1.path, params[0..S.MaxParams]).?;
    const dr1 = try S.dispatch({}, a, @constCast(&r), line1, rid1, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqual(@as(u16, 200), dr1.res.status);
    try std.testing.expectEqualStrings("p", dr1.res.body);
    try std.testing.expect(dr1.keep_alive);

    const line2 = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    const rid2 = S.match(line2.method, line2.path, params[0..S.MaxParams]).?;
    const dr2 = try S.dispatch({}, a, @constCast(&r), line2, rid2, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqual(@as(u16, 200), dr2.res.status);
    try std.testing.expectEqualStrings("g", dr2.res.body);
}

test "dispatch: path param percent-decodes" {
    const S = router.Compiled(void, .{
        zhttp.get("/u/{id}", .{}, struct {
            fn h(_: void, req: anytype) !zhttp.Res {
                return zhttp.Res.text(200, req.param(.id));
            }
        }.h),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var params: [S.MaxParams][]u8 = undefined;
    var r = std.Io.Reader.fixed(
        "GET /u/a%2Fb HTTP/1.1\r\n" ++
            "\r\n",
    );

    const line = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    const dr = try S.dispatch({}, a, @constCast(&r), line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("a/b", dr.res.body);

    // This route isn't eligible for fast dispatch; ensure `dispatchFast` falls back correctly.
    var r2 = std.Io.Reader.fixed(
        "GET /u/a%2Fb HTTP/1.1\r\n" ++
            "\r\n",
    );
    const line2 = try request.parseRequestLineBorrowed(@constCast(&r2), 8 * 1024);
    const rid2 = S.match(line2.method, line2.path, params[0..S.MaxParams]).?;
    const dr2 = try S.dispatchFast({}, a, @constCast(&r2), line2, rid2, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("a/b", dr2.res.body);
}

test "dispatchFast: routes with header needs fall back to full dispatch" {
    const H = struct { host: parse.String };

    const S = router.Compiled(void, .{
        zhttp.get("/x", .{ .headers = H }, struct {
            fn h(_: void, req: anytype) !zhttp.Res {
                _ = req.header(.host);
                return zhttp.Res.text(200, "ok");
            }
        }.h),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var params: [S.MaxParams][]u8 = undefined;
    var r = std.Io.Reader.fixed(
        "GET /x HTTP/1.1\r\n" ++
            "Host: example\r\n" ++
            "\r\n",
    );

    const line = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    const dr = try S.dispatchFast({}, a, @constCast(&r), line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("ok", dr.res.body);
}

test "query: repeated keys last-wins, SliceOf collects" {
    const ReqLast = request.Request(
        struct {},
        struct { k: parse.Optional(parse.String) },
        &.{},
    );
    const ReqList = request.Request(
        struct {},
        struct { k: parse.SliceOf(parse.String) },
        &.{},
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);

    {
        const query = try gpa.dupe(u8, "k=one&k=two");
        defer gpa.free(query);
        const line: request.RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
        var reqv = ReqLast.init(gpa, line, &.{});
        defer reqv.deinit(gpa);
        try reqv.parseQuery(gpa);
        try std.testing.expectEqualStrings("two", reqv.queryParam(.k).?);
    }

    {
        const query = try gpa.dupe(u8, "k=one&k=two");
        defer gpa.free(query);
        const line: request.RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
        var reqv = ReqList.init(gpa, line, &.{});
        defer reqv.deinit(gpa);
        try reqv.parseQuery(gpa);
        const items = reqv.queryParam(.k);
        try std.testing.expectEqual(@as(usize, 2), items.len);
        try std.testing.expectEqualStrings("one", items[0]);
        try std.testing.expectEqualStrings("two", items[1]);
    }
}

test "headers: trim value + case-insensitive match" {
    const ReqT = request.Request(
        struct { host: parse.Optional(parse.String) },
        struct {},
        &.{},
    );
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = std.Io.Reader.fixed("hOsT:\t  example.com \t\r\n\r\n");
    try reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024);
    try std.testing.expectEqualStrings("example.com", reqv.header(.host).?);
}

test "headers: transfer-encoding list sets chunked" {
    const ReqT = request.Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = std.Io.Reader.fixed("Transfer-Encoding: gzip, chunked\r\n\r\n");
    try reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024);
    try std.testing.expectEqual(request.BodyKind.chunked, reqv.base.body_kind);
}

test "chunked: invalid chunk CRLF rejected" {
    const ReqT = request.Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = std.Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n1\r\naXY0\r\n\r\n");
    try reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024);
    try std.testing.expectError(error.BadRequest, reqv.discardUnreadBody(@constCast(&r)));
}

test "chunked: truncated body yields EndOfStream" {
    const ReqT = request.Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = std.Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n1\r\na");
    try reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024);
    try std.testing.expectError(error.EndOfStream, reqv.discardUnreadBody(@constCast(&r)));
}

test "bodyAll: max_bytes enforced" {
    const ReqT = request.Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: request.RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = std.Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    try reqv.parseHeaders(gpa, @constCast(&r), 8 * 1024);
    try std.testing.expectError(error.PayloadTooLarge, reqv.bodyAll(gpa, @constCast(&r), 4));
}

test "discardHeadersOnly: consumes until blank line" {
    var r = std.Io.Reader.fixed("A: 1\r\nB: 2\r\n\r\nGET / HTTP/1.1\r\n");
    try request.discardHeadersOnly(@constCast(&r), 8 * 1024);
    const line = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    try std.testing.expectEqual(zhttp.Method.GET, line.method);
    try std.testing.expectEqualStrings("/", line.path);
}

test "discardHeadersOnly: max bytes enforced" {
    var r = std.Io.Reader.fixed("A: 1234567890\r\n\r\n");
    try std.testing.expectError(error.HeadersTooLarge, request.discardHeadersOnly(@constCast(&r), 8));
}

test "request line: rejects non-absolute path target" {
    var r = std.Io.Reader.fixed("GET http://example.com/ HTTP/1.1\r\n");
    try std.testing.expectError(error.BadRequest, request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024));
}

test "request line: max length enforced" {
    var r = std.Io.Reader.fixed("GET /abcd HTTP/1.1\r\n");
    try std.testing.expectError(error.UriTooLong, request.parseRequestLineBorrowed(@constCast(&r), 4));
}

test "router: trailing slash does not match exact literal" {
    const S = router.Compiled(void, .{
        zhttp.get("/a", .{}, struct {
            fn h(_: void, _: anytype) !zhttp.Res {
                return zhttp.Res.text(200, "a");
            }
        }.h),
    }, .{});

    var params: [S.MaxParams][]u8 = undefined;
    var p1 = "/a/".*;
    try std.testing.expectEqual(@as(?u16, null), S.match(.GET, p1[0..], params[0..S.MaxParams]));
}

test "handler: zero-arg handler supported" {
    const S = router.Compiled(void, .{
        zhttp.get("/a", .{}, struct {
            fn h() !zhttp.Res {
                return zhttp.Res.text(200, "x");
            }
        }.h),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var params: [S.MaxParams][]u8 = undefined;
    var r = std.Io.Reader.fixed("GET /a HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    const dr = try S.dispatch({}, a, @constCast(&r), line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("x", dr.res.body);
}

test "handler: ctx-only handler supported" {
    const Ctx = struct { v: u8 };
    const S = router.Compiled(Ctx, .{
        zhttp.get("/a", .{}, struct {
            fn h(ctx: *Ctx) !zhttp.Res {
                return zhttp.Res.text(200, if (ctx.v == 1) "ok" else "bad");
            }
        }.h),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx: Ctx = .{ .v = 1 };
    var params: [S.MaxParams][]u8 = undefined;
    var r = std.Io.Reader.fixed("GET /a HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    const dr = try S.dispatch(&ctx, a, @constCast(&r), line, rid, params[0..S.MaxParams], 8 * 1024);
    try std.testing.expectEqualStrings("ok", dr.res.body);
}

test "dispatch: invalid path percent-encoding rejected" {
    const S = router.Compiled(void, .{
        zhttp.get("/u/{id}", .{}, struct {
            fn h(_: void, _: anytype) !zhttp.Res {
                return zhttp.Res.text(200, "x");
            }
        }.h),
    }, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var params: [S.MaxParams][]u8 = undefined;
    var r = std.Io.Reader.fixed("GET /u/%ZZ HTTP/1.1\r\n\r\n");
    const line = try request.parseRequestLineBorrowed(@constCast(&r), 8 * 1024);
    const rid = S.match(line.method, line.path, params[0..S.MaxParams]).?;
    try std.testing.expectError(error.InvalidPercentEncoding, S.dispatch({}, a, @constCast(&r), line, rid, params[0..S.MaxParams], 8 * 1024));
}

test "server: benchmark fast-single route responds + pipelines" {
    const Bench = struct {
        fn plaintext(_: void, _: anytype) !zhttp.Res {
            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Server: F\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: 13\r\n" ++
                "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
                "\r\n" ++
                "Hello, World!";
            return zhttp.Res.rawResponse(resp);
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const SrvT = zhttp.Server(.{
        .routes = .{
            zhttp.get("/plaintext", .{}, Bench.plaintext),
        },
        .config = .{
            .read_buffer = 64 * 1024,
            .write_buffer = 16 * 1024,
            .fast_benchmark = true,
            .fast_benchmark_empty_headers = true,
        },
    });

    const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.init(std.testing.allocator, io, addr0, {});
    defer server.deinit();

    const port: u16 = server.listener.socket.address.getPort();
    try std.testing.expect(port != 0);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, SrvT.run, .{&server});

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var stream = try std.Io.net.IpAddress.connect(addr, io, .{ .mode = .stream });
    defer stream.close(io);

    const req = "GET /plaintext HTTP/1.1\r\n\r\n";
    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "\r\n" ++
        "Hello, World!";
    const resp_len: usize = resp.len;

    var rb: [4 * 1024]u8 = undefined;
    var wb: [128]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    // Two pipelined requests.
    try sw.interface.writeAll(req ++ req);
    try sw.interface.flush();

    var got1: [resp_len]u8 = undefined;
    var got2: [resp_len]u8 = undefined;
    try sr.interface.readSliceAll(got1[0..]);
    try sr.interface.readSliceAll(got2[0..]);
    try std.testing.expect(std.mem.eql(u8, got1[0..], resp));
    try std.testing.expect(std.mem.eql(u8, got2[0..], resp));

    group.cancel(io);
    group.await(io) catch {};
}

test "server: benchmark fast-single route handles full request headers" {
    const Bench = struct {
        fn plaintext(_: void, _: anytype) !zhttp.Res {
            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Server: F\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: 13\r\n" ++
                "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
                "\r\n" ++
                "Hello, World!";
            return zhttp.Res.rawResponse(resp);
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const SrvT = zhttp.Server(.{
        .routes = .{
            zhttp.get("/plaintext", .{}, Bench.plaintext),
        },
        .config = .{
            .read_buffer = 64 * 1024,
            .write_buffer = 16 * 1024,
            .fast_benchmark = true,
        },
    });

    const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.init(std.testing.allocator, io, addr0, {});
    defer server.deinit();

    const port: u16 = server.listener.socket.address.getPort();
    try std.testing.expect(port != 0);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, SrvT.run, .{&server});

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var stream = try std.Io.net.IpAddress.connect(addr, io, .{ .mode = .stream });
    defer stream.close(io);

    const req =
        "GET /plaintext HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Connection: keep-alive\r\n" ++
        "\r\n";
    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "\r\n" ++
        "Hello, World!";
    const resp_len: usize = resp.len;

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    // Two pipelined requests (with headers).
    try sw.interface.writeAll(req ++ req);
    try sw.interface.flush();

    var got1: [resp_len]u8 = undefined;
    var got2: [resp_len]u8 = undefined;
    try sr.interface.readSliceAll(got1[0..]);
    try sr.interface.readSliceAll(got2[0..]);
    try std.testing.expect(std.mem.eql(u8, got1[0..], resp));
    try std.testing.expect(std.mem.eql(u8, got2[0..], resp));

    group.cancel(io);
    group.await(io) catch {};
}

test "server: Connection close header closes socket" {
    const Bench = struct {
        fn plaintext(_: void, _: anytype) !zhttp.Res {
            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Server: F\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: 13\r\n" ++
                "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
                "\r\n" ++
                "Hello, World!";
            return zhttp.Res.rawResponse(resp);
        }
    };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Disable fast benchmark mode here so we honor `Connection: close`.
    const SrvT = zhttp.Server(.{
        .routes = .{
            zhttp.get("/plaintext", .{}, Bench.plaintext),
        },
        .config = .{
            .read_buffer = 64 * 1024,
            .write_buffer = 16 * 1024,
            .fast_benchmark = false,
        },
    });

    const addr0: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.init(std.testing.allocator, io, addr0, {});
    defer server.deinit();

    const port: u16 = server.listener.socket.address.getPort();
    try std.testing.expect(port != 0);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, SrvT.run, .{&server});

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    var stream = try std.Io.net.IpAddress.connect(addr, io, .{ .mode = .stream });
    defer stream.close(io);

    const req =
        "GET /plaintext HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 13\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "\r\n" ++
        "Hello, World!";
    const resp_len: usize = resp.len;

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll(req);
    try sw.interface.flush();

    var got: [resp_len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expect(std.mem.eql(u8, got[0..], resp));

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));

    group.cancel(io);
    group.await(io) catch {};
}
