const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Method = @import("server.zig").Method;
const parse = @import("parse.zig");
const urldecode = @import("urldecode.zig");

pub const Version = enum { http10, http11 };

pub const BodyKind = enum { none, content_length, chunked };

pub const Base = struct {
    version: Version,

    connection_close: bool = false,

    body_kind: BodyKind = .none,
    body_remaining: usize = 0, // for content-length bodies
};

pub const ParseLineError = error{
    BadRequest,
    UriTooLong,
    EndOfStream,
} || Io.Reader.Error || Allocator.Error;

pub const ParseHeadersError = error{
    BadRequest,
    HeadersTooLarge,
} || Io.Reader.Error || parse.CaptureError || urldecode.DecodeError || Allocator.Error;

pub fn discardHeadersOnly(
    r: *Io.Reader,
    max_header_bytes: usize,
) (error{ BadRequest, HeadersTooLarge } || Io.Reader.Error)!void {
    var total: usize = 0;
    while (true) {
        const line0_incl = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.HeadersTooLarge,
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };
        total += line0_incl.len;
        if (total > max_header_bytes) return error.HeadersTooLarge;

        const line0 = line0_incl[0 .. line0_incl.len - 1];
        const line = trimCR(line0);
        if (line.len == 0) return;
    }
}

fn trimCR(line: []u8) []u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn trimSpaces(s: []u8) []u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) b -= 1;
    return s[a..b];
}

fn parseMethod(m: []const u8) Method {
    return if (std.mem.eql(u8, m, "GET"))
        .GET
    else if (std.mem.eql(u8, m, "POST"))
        .POST
    else if (std.mem.eql(u8, m, "PUT"))
        .PUT
    else if (std.mem.eql(u8, m, "DELETE"))
        .DELETE
    else if (std.mem.eql(u8, m, "PATCH"))
        .PATCH
    else if (std.mem.eql(u8, m, "HEAD"))
        .HEAD
    else if (std.mem.eql(u8, m, "OPTIONS"))
        .OPTIONS
    else if (std.mem.eql(u8, m, "TRACE"))
        .TRACE
    else if (std.mem.eql(u8, m, "CONNECT"))
        .CONNECT
    else
        .OTHER;
}

fn parseVersion(v: []const u8) ?Version {
    if (std.mem.eql(u8, v, "HTTP/1.1")) return .http11;
    if (std.mem.eql(u8, v, "HTTP/1.0")) return .http10;
    return null;
}

pub const RequestLine = struct {
    method: Method,
    version: Version,
    path: []u8,
    query: []u8,
};

pub fn parseRequestLineBorrowed(r: *Io.Reader, max_line_len: usize) ParseLineError!RequestLine {
    const line0_incl = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.StreamTooLong => return error.UriTooLong,
        error.ReadFailed => return error.ReadFailed,
    };
    const line0 = line0_incl[0 .. line0_incl.len - 1]; // strip '\n'
    if (line0.len > max_line_len) return error.UriTooLong;
    const line = trimCR(line0);

    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadRequest;
    const sp2 = std.mem.indexOfScalarPos(u8, line, sp1 + 1, ' ') orelse return error.BadRequest;

    const method_str = line[0..sp1];
    const target = line[sp1 + 1 .. sp2];
    const version_str = line[sp2 + 1 ..];

    const method = parseMethod(method_str);
    const version = parseVersion(version_str) orelse return error.BadRequest;

    if (target.len == 0 or target[0] != '/') return error.BadRequest;

    const qpos = std.mem.indexOfScalar(u8, target, '?');
    const path_raw = if (qpos) |p| target[0..p] else target;
    const query_raw: []u8 = if (qpos) |p| target[p + 1 ..] else target[0..0];

    return .{
        .method = method,
        .version = version,
        .path = path_raw,
        .query = query_raw,
    };
}

pub fn parseRequestLine(r: *Io.Reader, allocator: Allocator, max_line_len: usize) ParseLineError!RequestLine {
    const borrowed = try parseRequestLineBorrowed(r, max_line_len);
    const path = try allocator.dupe(u8, borrowed.path);
    const query = try allocator.dupe(u8, borrowed.query);

    return .{
        .method = borrowed.method,
        .version = borrowed.version,
        .path = path,
        .query = query,
    };
}

fn parseContentLength(v: []const u8) ?usize {
    return std.fmt.parseInt(usize, v, 10) catch null;
}

fn headerIs(name: []const u8, comptime wanted: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, wanted);
}

fn containsTokenIgnoreCase(value: []const u8, comptime token: []const u8) bool {
    // A minimal token scanner split on commas.
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (std.ascii.eqlIgnoreCase(t, token)) return true;
    }
    return false;
}

pub fn RequestP(comptime Headers: type, comptime Query: type, comptime Params: type, comptime param_names: []const []const u8) type {
    const HeaderLookup = parse.Lookup(Headers, .header);
    const QueryLookup = parse.Lookup(Query, .query);
    const ParamFields = comptime parse.structFields(Params);

    const ParamIndices = comptime blk: {
        var out: [ParamFields.len]u8 = undefined;
        for (ParamFields, 0..) |f, fi| {
            var found: ?u8 = null;
            for (param_names, 0..) |pn, pi| {
                if (std.mem.eql(u8, pn, f.name)) found = @intCast(pi);
            }
            if (found == null) {
                @compileError("params field '" ++ f.name ++ "' is not present in the route pattern");
            }
            out[fi] = found.?;
        }
        break :blk out;
    };

    return struct {
        arena: Allocator,
        base: Base,
        query_raw: []u8,
        reader: ?*Io.Reader = null,
        headers: Headers = parse.emptyStruct(Headers),
        query: Query = parse.emptyStruct(Query),
        params_parsed: Params = parse.emptyStruct(Params),
        params_raw: [param_names.len][]u8 = undefined,

        const Self = @This();

        pub const ParamNames: []const []const u8 = param_names;

        pub fn init(arena: Allocator, line: RequestLine, params_in: []const []u8) Self {
            std.debug.assert(params_in.len == param_names.len);
            var self: Self = .{
                .arena = arena,
                .base = .{
                    .version = line.version,
                },
                .query_raw = line.query,
            };
            inline for (param_names, 0..) |_, i| {
                self.params_raw[i] = params_in[i];
            }
            return self;
        }

        pub fn allocator(self: *const Self) Allocator {
            return self.arena;
        }

        pub fn deinit(self: *Self, a: Allocator) void {
            parse.destroyStruct(&self.headers, a);
            parse.destroyStruct(&self.query, a);
            parse.destroyStruct(&self.params_parsed, a);
        }

        /// Get a captured header by field name, e.g. `req.header(.host)`.
        pub fn header(self: *const Self, comptime field: @EnumLiteral()) @TypeOf(@field(self.headers, @tagName(field)).get()) {
            return @field(self.headers, @tagName(field)).get();
        }

        /// Get a captured query param by field name, e.g. `req.queryParam(.page)`.
        pub fn queryParam(self: *const Self, comptime field: @EnumLiteral()) @TypeOf(@field(self.query, @tagName(field)).get()) {
            return @field(self.query, @tagName(field)).get();
        }

        /// Get a raw path param slice by name, e.g. `req.param(.id)`.
        /// This is always a string slice (percent-decoded).
        pub fn param(self: *const Self, comptime name: @EnumLiteral()) []const u8 {
            const idx = comptime blk: {
                const wanted = @tagName(name);
                var idx: ?usize = null;
                for (param_names, 0..) |pn, i| {
                    if (std.mem.eql(u8, pn, wanted)) idx = i;
                }
                if (idx == null) @compileError("no param '" ++ wanted ++ "' for this route");
                break :blk idx;
            };
            return self.params_raw[idx.?];
        }

        /// Get a typed path param value from `.params` captures (or middleware `Needs.params`),
        /// e.g. `req.paramValue(.id)`.
        pub fn paramValue(self: *const Self, comptime field: @EnumLiteral()) @TypeOf(@field(self.params_parsed, @tagName(field)).get()) {
            return @field(self.params_parsed, @tagName(field)).get();
        }

        pub fn keepAlive(self: *const Self) bool {
            return self.base.version == .http11 and !self.base.connection_close;
        }

        pub fn parseParams(self: *Self, a: Allocator) !void {
            if (ParamFields.len == 0) return;
            // reset captures each request
            self.params_parsed = parse.emptyStruct(Params);
            inline for (ParamFields, 0..) |f, fi| {
                const raw = self.params_raw[ParamIndices[fi]];
                try @field(self.params_parsed, f.name).parse(a, raw);
            }
            try parse.doneParsingStruct(&self.params_parsed, &([_]bool{true} ** ParamFields.len));
        }

        pub fn parseQuery(self: *Self, a: Allocator) !void {
            if (QueryLookup.count == 0) return;
            var present: [QueryLookup.count]bool = .{false} ** QueryLookup.count;

            var i: usize = 0;
            const q = self.query_raw;
            while (i <= q.len) {
                const amp = std.mem.indexOfScalarPos(u8, q, i, '&') orelse q.len;
                const part = q[i..amp];
                i = amp + 1;
                if (part.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, part, '=');
                const k = if (eq) |p| part[0..p] else part;
                var v = if (eq) |p| part[p + 1 ..] else part[part.len..part.len];

                if (QueryLookup.find(k)) |idx| {
                    v = try urldecode.decodeInPlace(v, .query_value);
                    present[idx] = true;
                    const q_fields = comptime parse.structFields(Query);
                    inline for (q_fields, 0..) |f, fi| {
                        if (idx == @as(u16, @intCast(fi))) {
                            try @field(self.query, f.name).parse(a, v);
                            break;
                        }
                    }
                }
            }

            try parse.doneParsingStruct(&self.query, present[0..]);
        }

        pub fn parseHeaders(self: *Self, a: Allocator, r: *Io.Reader, max_header_bytes: usize) ParseHeadersError!void {
            self.reader = r;
            if (HeaderLookup.count != 0) {
                // reset captures each request
                self.headers = parse.emptyStruct(Headers);
            }
            var present: [HeaderLookup.count]bool = .{false} ** HeaderLookup.count;

            var total: usize = 0;
            var content_length: ?usize = null;
            var has_chunked: bool = false;

            while (true) {
                const line0_incl = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
                    error.StreamTooLong => return error.HeadersTooLarge,
                    error.EndOfStream => return error.EndOfStream,
                    error.ReadFailed => return error.ReadFailed,
                };
                const line0 = line0_incl[0 .. line0_incl.len - 1];
                var line = trimCR(line0);
                total += line0_incl.len;
                if (total > max_header_bytes) return error.HeadersTooLarge;

                if (line.len == 0) break;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
                const name = line[0..colon];
                var value = line[colon + 1 ..];
                value = trimSpaces(value);

                if (headerIs(name, "connection")) {
                    if (containsTokenIgnoreCase(value, "close")) self.base.connection_close = true;
                } else if (headerIs(name, "content-length")) {
                    const parsed = parseContentLength(value) orelse return error.BadRequest;
                    if (content_length) |prev| {
                        if (prev != parsed) return error.BadRequest;
                    } else {
                        content_length = parsed;
                    }
                } else if (headerIs(name, "transfer-encoding")) {
                    if (containsTokenIgnoreCase(value, "chunked")) has_chunked = true;
                }

                if (HeaderLookup.count != 0) {
                    if (HeaderLookup.find(name)) |idx| {
                        present[idx] = true;
                        const h_fields = comptime parse.structFields(Headers);
                        inline for (h_fields, 0..) |f, fi| {
                            if (idx == @as(u16, @intCast(fi))) {
                                try @field(self.headers, f.name).parse(a, value);
                                break;
                            }
                        }
                    }
                }
            }

            if (has_chunked and content_length != null) return error.BadRequest;
            if (has_chunked) {
                self.base.body_kind = .chunked;
            } else if (content_length) |cl| {
                self.base.body_kind = if (cl == 0) .none else .content_length;
                self.base.body_remaining = cl;
            } else {
                self.base.body_kind = .none;
            }

            if (HeaderLookup.count != 0) {
                try parse.doneParsingStruct(&self.headers, present[0..]);
            }
        }

        fn readExact(r: *Io.Reader, buf: []u8) Io.Reader.Error!void {
            try r.readSliceAll(buf);
        }

        fn bodyAllFrom(self: *Self, a: Allocator, r: *Io.Reader, max_bytes: usize) ![]const u8 {
            return switch (self.base.body_kind) {
                .none => "",
                .content_length => blk: {
                    const n = self.base.body_remaining;
                    if (n > max_bytes) return error.PayloadTooLarge;
                    const buf = try a.alloc(u8, n);
                    try readExact(r, buf);
                    self.base.body_remaining = 0;
                    break :blk buf;
                },
                .chunked => blk: {
                    var out: std.ArrayList(u8) = .empty;
                    errdefer out.deinit(a);
                    while (true) {
                        const line0_incl = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
                            error.StreamTooLong => return error.BadRequest,
                            error.EndOfStream => return error.EndOfStream,
                            error.ReadFailed => return error.ReadFailed,
                        };
                        const line0 = line0_incl[0 .. line0_incl.len - 1];
                        const line = trimCR(line0);
                        const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
                        const size_str = std.mem.trim(u8, line[0..semi], " \t");
                        const size = std.fmt.parseInt(usize, size_str, 16) catch return error.BadRequest;
                        if (size == 0) {
                            // trailers
                            while (true) {
                                const t0_incl = try r.takeDelimiterInclusive('\n');
                                const t0 = t0_incl[0 .. t0_incl.len - 1];
                                const t = trimCR(t0);
                                if (t.len == 0) break;
                            }
                            break;
                        }
                        const start = out.items.len;
                        try out.resize(a, start + size);
                        try readExact(r, out.items[start..][0..size]);
                        if (out.items.len > max_bytes) return error.PayloadTooLarge;
                        // chunk CRLF
                        var crlf: [2]u8 = undefined;
                        try readExact(r, crlf[0..]);
                        if (crlf[0] != '\r' or crlf[1] != '\n') return error.BadRequest;
                    }
                    self.base.body_kind = .none;
                    break :blk try out.toOwnedSlice(a);
                },
            };
        }

        /// Read and return the full request body, up to `max_bytes`.
        ///
        /// Requires headers to have been parsed for this request.
        pub fn bodyAll(self: *Self, max_bytes: usize) ![]const u8 {
            const r = self.reader orelse return error.BadRequest;
            return bodyAllFrom(self, self.arena, r, max_bytes);
        }

        fn discardUnreadBodyFrom(self: *Self, r: *Io.Reader) !void {
            switch (self.base.body_kind) {
                .none => return,
                .content_length => {
                    var remaining = self.base.body_remaining;
                    while (remaining != 0) {
                        const tossed = try r.discard(.limited(remaining));
                        remaining -= tossed;
                    }
                    self.base.body_remaining = 0;
                    self.base.body_kind = .none;
                },
                .chunked => {
                    while (true) {
                        const line0_incl = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
                            error.StreamTooLong => return error.BadRequest,
                            error.EndOfStream => return error.EndOfStream,
                            error.ReadFailed => return error.ReadFailed,
                        };
                        const line0 = line0_incl[0 .. line0_incl.len - 1];
                        const line = trimCR(line0);
                        const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
                        const size_str = std.mem.trim(u8, line[0..semi], " \t");
                        const size = std.fmt.parseInt(usize, size_str, 16) catch return error.BadRequest;
                        if (size == 0) {
                            while (true) {
                                const t0_incl = try r.takeDelimiterInclusive('\n');
                                const t0 = t0_incl[0 .. t0_incl.len - 1];
                                const t = trimCR(t0);
                                if (t.len == 0) break;
                            }
                            break;
                        }
                        var remaining = size;
                        while (remaining != 0) {
                            const tossed = try r.discard(.limited(remaining));
                            remaining -= tossed;
                        }
                        var crlf: [2]u8 = undefined;
                        try readExact(r, crlf[0..]);
                        if (crlf[0] != '\r' or crlf[1] != '\n') return error.BadRequest;
                    }
                    self.base.body_kind = .none;
                },
            }
        }

        /// Discard any unread request body bytes so the connection can be reused.
        ///
        /// Requires headers to have been parsed for this request.
        pub fn discardUnreadBody(self: *Self) !void {
            const r = self.reader orelse return error.BadRequest;
            return discardUnreadBodyFrom(self, r);
        }
    };
}

pub fn Request(comptime Headers: type, comptime Query: type, comptime param_names: []const []const u8) type {
    return RequestP(Headers, Query, struct {}, param_names);
}

test "query capture + decode" {
    const ReqT = Request(
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

    const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    try reqv.parseQuery(gpa);
    try std.testing.expectEqualStrings("alice bob", reqv.queryParam(.name).?);
    try std.testing.expectEqual(@as(u32, 10), reqv.queryParam(.page).?);
}

test "header capture required vs optional" {
    const ReqOpt = Request(
        struct { host: parse.Optional(parse.String) },
        struct {},
        &.{},
    );
    const ReqReq = Request(
        struct { host: parse.String },
        struct {},
        &.{},
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };

    {
        var r = Io.Reader.fixed("User-Agent: x\r\n\r\n");
        var reqv = ReqOpt.init(gpa, line, &.{});
        defer reqv.deinit(gpa);
        try reqv.parseHeaders(gpa, &r, 1024);
        try std.testing.expect(reqv.header(.host) == null);
    }

    {
        var r = Io.Reader.fixed("User-Agent: x\r\n\r\n");
        var reqv = ReqReq.init(gpa, line, &.{});
        defer reqv.deinit(gpa);
        try std.testing.expectError(error.MissingRequired, reqv.parseHeaders(gpa, &r, 1024));
    }
}

test "chunked bodyAll" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n0\r\n\r\n");
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    try reqv.parseHeaders(gpa, &r, 1024);
    const body = try reqv.bodyAll(32);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("Wiki", body);
}

test "request line: borrowed parses path/query" {
    var r = Io.Reader.fixed("GET /a/b?x=1 HTTP/1.1\r\n");
    const line = try parseRequestLineBorrowed(&r, 8 * 1024);
    try std.testing.expectEqual(Method.GET, line.method);
    try std.testing.expectEqual(Version.http11, line.version);
    try std.testing.expectEqualStrings("/a/b", line.path);
    try std.testing.expectEqualStrings("x=1", line.query);
}

test "request line: owned duplicates path/query" {
    var r = Io.Reader.fixed("GET /hello HTTP/1.1\r\n");
    const gpa = std.testing.allocator;
    const line = try parseRequestLine(&r, gpa, 8 * 1024);
    defer gpa.free(line.path);
    defer gpa.free(line.query);
    try std.testing.expectEqualStrings("/hello", line.path);
    try std.testing.expectEqualStrings("", line.query);
}

test "request line: rejects non-absolute path target" {
    var r = Io.Reader.fixed("GET http://example.com/ HTTP/1.1\r\n");
    try std.testing.expectError(error.BadRequest, parseRequestLineBorrowed(&r, 8 * 1024));
}

test "request line: max length enforced" {
    var r = Io.Reader.fixed("GET /abcd HTTP/1.1\r\n");
    try std.testing.expectError(error.UriTooLong, parseRequestLineBorrowed(&r, 4));
}

test "discardHeadersOnly: consumes until blank line" {
    var r = Io.Reader.fixed("A: 1\r\nB: 2\r\n\r\nGET / HTTP/1.1\r\n");
    try discardHeadersOnly(&r, 8 * 1024);
    const line = try parseRequestLineBorrowed(&r, 8 * 1024);
    try std.testing.expectEqual(Method.GET, line.method);
    try std.testing.expectEqualStrings("/", line.path);
}

test "discardHeadersOnly: max bytes enforced" {
    var r = Io.Reader.fixed("A: 1234567890\r\n\r\n");
    try std.testing.expectError(error.HeadersTooLarge, discardHeadersOnly(&r, 8));
}

test "headers: underscore field matches dash header" {
    const ReqT = Request(
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
    const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Type: text/plain\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectEqualStrings("text/plain", reqv.header(.content_type).?);
}

test "headers: too large rejected" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("X: 1234567890\r\n\r\n");
    try std.testing.expectError(error.HeadersTooLarge, reqv.parseHeaders(gpa, &r, 8));
}

test "headers: duplicate Content-Length mismatch rejected" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Length: 1\r\nContent-Length: 2\r\n\r\n");
    try std.testing.expectError(error.BadRequest, reqv.parseHeaders(gpa, &r, 8 * 1024));
}

test "headers: chunked + Content-Length rejected" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n");
    try std.testing.expectError(error.BadRequest, reqv.parseHeaders(gpa, &r, 8 * 1024));
}

test "headers: Connection close disables keep-alive" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Connection: keep-alive, Close\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expect(!reqv.keepAlive());
}

test "headers: trim value + case-insensitive match" {
    const ReqT = Request(
        struct { host: parse.Optional(parse.String) },
        struct {},
        &.{},
    );
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("hOsT:\t  example.com \t\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectEqualStrings("example.com", reqv.header(.host).?);
}

test "headers: transfer-encoding list sets chunked" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Transfer-Encoding: gzip, chunked\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectEqual(BodyKind.chunked, reqv.base.body_kind);
}

test "chunked: invalid chunk CRLF rejected" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n1\r\naXY0\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectError(error.BadRequest, reqv.discardUnreadBody());
}

test "chunked: truncated body yields EndOfStream" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n1\r\na");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectError(error.EndOfStream, reqv.discardUnreadBody());
}

test "bodyAll: content-length" {
    const ReqT = Request(struct {}, struct {}, &.{});

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    const body = try reqv.bodyAll(16);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

test "bodyAll: max_bytes enforced" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectError(error.PayloadTooLarge, reqv.bodyAll(4));
}

test "query: required missing rejected" {
    const ReqT = Request(
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
    const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    try std.testing.expectError(error.MissingRequired, reqv.parseQuery(gpa));
}

test "query: invalid percent-encoding rejected" {
    const ReqT = Request(
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
    const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);

    try std.testing.expectError(error.InvalidPercentEncoding, reqv.parseQuery(gpa));
}

test "query: repeated keys last-wins, SliceOf collects" {
    const ReqLast = Request(
        struct {},
        struct { k: parse.Optional(parse.String) },
        &.{},
    );
    const ReqList = Request(
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
        const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
        var reqv = ReqLast.init(gpa, line, &.{});
        defer reqv.deinit(gpa);
        try reqv.parseQuery(gpa);
        try std.testing.expectEqualStrings("two", reqv.queryParam(.k).?);
    }

    {
        const query = try gpa.dupe(u8, "k=one&k=two");
        defer gpa.free(query);
        const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };
        var reqv = ReqList.init(gpa, line, &.{});
        defer reqv.deinit(gpa);
        try reqv.parseQuery(gpa);
        const items = reqv.queryParam(.k);
        try std.testing.expectEqual(@as(usize, 2), items.len);
        try std.testing.expectEqualStrings("one", items[0]);
        try std.testing.expectEqualStrings("two", items[1]);
    }
}

test "parseHeaders: rejects header line without colon" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("NoColon\r\n\r\n");
    try std.testing.expectError(error.BadRequest, reqv.parseHeaders(gpa, &r, 8 * 1024));
}

test "parseHeaders: repeated Content-Length same value accepted" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Content-Length: 2\r\nContent-Length: 2\r\n\r\nok");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    const body = try reqv.bodyAll(8);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("ok", body);
}

test "parseHeaders: invalid Content-Length rejected" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Content-Length: nope\r\n\r\n");
    try std.testing.expectError(error.BadRequest, reqv.parseHeaders(gpa, &r, 8 * 1024));
}

test "chunked bodyAll: chunk extensions supported" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n4;ext=1\r\nWiki\r\n0\r\n\r\n");
    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    try reqv.parseHeaders(gpa, &r, 1024);
    const body = try reqv.bodyAll(32);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("Wiki", body);
}

test "bodyAll/discardUnreadBody: require parseHeaders first" {
    const ReqT = Request(struct {}, struct {}, &.{});
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .POST, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    try std.testing.expectError(error.BadRequest, reqv.bodyAll(1));
    try std.testing.expectError(error.BadRequest, reqv.discardUnreadBody());
}

test "parseQuery: key without '=' treated as empty value" {
    const ReqT = Request(
        struct {},
        struct { k: parse.Optional(parse.String) },
        &.{},
    );
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "k");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = .GET, .version = .http11, .path = path, .query = query };

    var reqv = ReqT.init(gpa, line, &.{});
    defer reqv.deinit(gpa);
    try reqv.parseQuery(gpa);
    try std.testing.expectEqualStrings("", reqv.queryParam(.k).?);
}
