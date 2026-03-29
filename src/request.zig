const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const parse = @import("parse.zig");
const route_decl = @import("route_decl.zig");
const urldecode = @import("urldecode.zig");
const util = @import("util.zig");

pub const Version = enum { http10, http11 };

pub const BodyOpError = error{
    BadRequest,
    PayloadTooLarge,
    EndOfStream,
    ReadFailed,
    OutOfMemory,
};

const BodyFraming = enum {
    none,
    chunked,
    content_length,
    content_length_zero,
};

const DownloadedBody = struct {
    bytes: []u8,
    framing: BodyFraming,
};

const FailedBody = struct {
    err: BodyOpError,
    framing: BodyFraming,
};

pub const Body = union(enum) {
    none,
    chunked,
    content_length: usize,
    downloaded: DownloadedBody,
    streamed: BodyFraming,
    discarded: BodyFraming,
    errored: FailedBody,
};

pub const Base = struct {
    arena: Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,

    version: Version,

    connection_close: bool = false,

    body: Body = .none,
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

fn trimCR(line: []u8) []u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn trimSpaces(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) b -= 1;
    return s[a..b];
}

fn middlewareNameString(comptime name: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(name))) {
        .enum_literal => @tagName(name),
        .pointer => |p| switch (p.size) {
            .slice => blk: {
                if (p.child != u8) @compileError("middleware name slice must be []const u8");
                break :blk name;
            },
            .one => blk: {
                const cinfo = @typeInfo(p.child);
                if (cinfo != .array or cinfo.array.child != u8) {
                    @compileError("middleware name pointer must point to a byte array/string literal");
                }
                break :blk name[0..cinfo.array.len];
            },
            else => @compileError("unsupported middleware name type"),
        },
        .array => |a| blk: {
            if (a.child != u8) @compileError("middleware name array must be [N]u8");
            break :blk name[0..a.len];
        },
        else => @compileError("middleware name must be enum literal or string"),
    };
}

fn middlewareContextFieldName(comptime Ctx: type, comptime name: anytype) []const u8 {
    const wanted = middlewareNameString(name);
    if (!@hasField(Ctx, wanted)) @compileError("unknown middleware name '" ++ wanted ++ "'");
    return wanted;
}

fn middlewareContextFieldType(comptime Ctx: type, comptime name: anytype) type {
    return @FieldType(Ctx, middlewareContextFieldName(Ctx, name));
}

pub const RequestLine = struct {
    method: []const u8,
    version: Version,
    path: []u8,
    query: []u8,
};

/// Parses one request line and returns slices borrowed from the reader buffer.
pub fn parseRequestLineBorrowed(r: *Io.Reader, max_line_len: usize) ParseLineError!RequestLine {
    const line0_incl = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.StreamTooLong => return error.UriTooLong,
        error.ReadFailed => return error.ReadFailed,
    };
    if (line0_incl.len == 0) return error.BadRequest;
    if (line0_incl.len > max_line_len) return error.UriTooLong;
    var end: usize = line0_incl.len - 1; // strip '\n'
    if (end != 0 and line0_incl[end - 1] == '\r') end -= 1;
    const line = line0_incl[0..end];

    var sp1_opt: ?usize = null;
    var sp2_opt: ?usize = null;
    var qpos_opt: ?usize = null;
    {
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == ' ') {
                if (sp1_opt == null) {
                    sp1_opt = i;
                } else {
                    sp2_opt = i;
                    break;
                }
                continue;
            }
            if (sp1_opt != null and sp2_opt == null and c == '?') {
                qpos_opt = i;
            }
        }
    }
    const sp1 = sp1_opt orelse return error.BadRequest;
    if (sp1 == 0 or sp1 >= line.len) return error.BadRequest;
    const sp2 = sp2_opt orelse return error.BadRequest;
    if (sp2 == sp1 + 1 or sp2 >= line.len) return error.BadRequest;

    const method_str = line[0..sp1];
    const target = line[sp1 + 1 .. sp2];
    const version_str = line[sp2 + 1 ..];
    if (version_str.len == 0) return error.BadRequest;

    const version: Version = blk: {
        if (version_str.len == 8) {
            if (version_str[0] == 'H' and version_str[1] == 'T' and version_str[2] == 'T' and version_str[3] == 'P' and
                version_str[4] == '/' and version_str[5] == '1' and version_str[6] == '.' and version_str[7] == '1')
            {
                break :blk .http11;
            }
            if (version_str[0] == 'H' and version_str[1] == 'T' and version_str[2] == 'T' and version_str[3] == 'P' and
                version_str[4] == '/' and version_str[5] == '1' and version_str[6] == '.' and version_str[7] == '0')
            {
                break :blk .http10;
            }
        }
        return error.BadRequest;
    };

    if (target.len == 0 or target[0] != '/') return error.BadRequest;

    const qpos = if (qpos_opt) |p| p - (sp1 + 1) else null;
    const path_raw = if (qpos) |p| target[0..p] else target;
    const query_raw: []u8 = if (qpos) |p| target[p + 1 ..] else target[0..0];

    return .{
        .method = method_str,
        .version = version,
        .path = path_raw,
        .query = query_raw,
    };
}

fn headerIs(name: []const u8, comptime wanted: []const u8) bool {
    return util.asciiEqlLower(name, wanted);
}

fn containsTokenIgnoreCase(value: []const u8, comptime token: []const u8) bool {
    // A minimal token scanner split on commas.
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (util.asciiEqlLower(t, token)) return true;
    }
    return false;
}

fn routeParamNames(comptime pattern: []const u8) []const []const u8 {
    if (pattern.len == 0 or pattern[0] != '/') @compileError("route pattern must start with '/'");
    if (std.mem.eql(u8, pattern, "/")) return &.{};

    comptime var count: usize = 0;
    comptime {
        var start: usize = 1;
        while (start <= pattern.len) {
            const end = std.mem.indexOfScalarPos(u8, pattern, start, '/') orelse pattern.len;
            const seg = pattern[start..end];
            if (seg.len != 0 and seg[0] == '{' and seg[seg.len - 1] == '}') count += 1;
            if (end == pattern.len) break;
            start = end + 1;
        }
    }
    if (count == 0) return &.{};

    const out: [count][]const u8 = comptime blk: {
        var names: [count][]const u8 = undefined;
        var i: usize = 0;
        var start: usize = 1;
        while (start <= pattern.len) {
            const end = std.mem.indexOfScalarPos(u8, pattern, start, '/') orelse pattern.len;
            const seg = pattern[start..end];
            if (seg.len != 0 and seg[0] == '{' and seg[seg.len - 1] == '}') {
                const inner = seg[1 .. seg.len - 1];
                names[i] = if (inner.len != 0 and inner[0] == '*') inner[1..] else inner;
                i += 1;
            }
            if (end == pattern.len) break;
            start = end + 1;
        }
        break :blk names;
    };
    return out[0..];
}

pub fn RequestPWithPatternExt(
    comptime ServerPtr: type,
    comptime route_index: usize,
    comptime rd: route_decl.RouteDecl,
    comptime MwCtx: type,
) type {
    comptime {
        const ptr_info = @typeInfo(ServerPtr);
        if (ptr_info != .pointer or ptr_info.pointer.size != .one) {
            @compileError("ServerPtr must be a single-item pointer type");
        }
    }
    const ServerT = @typeInfo(ServerPtr).pointer.child;
    comptime {
        if (!@hasField(ServerT, "io")) @compileError("ServerPtr pointee must have field `io`");
        if (!@hasField(ServerT, "gpa")) @compileError("ServerPtr pointee must have field `gpa`");
        if (!@hasField(ServerT, "ctx")) @compileError("ServerPtr pointee must have field `ctx`");
        if (!@hasDecl(ServerT, "RouteStaticType")) @compileError("ServerPtr pointee must expose `pub fn RouteStaticType(comptime route_index: usize) type`");
        if (!@hasDecl(ServerT, "routeStatic")) @compileError("ServerPtr pointee must expose `pub fn routeStatic(self: *Server, comptime route_index: usize) *RouteStaticType(route_index)`");
        if (!@hasDecl(ServerT, "routeStaticConst")) @compileError("ServerPtr pointee must expose `pub fn routeStaticConst(self: *const Server, comptime route_index: usize) *const RouteStaticType(route_index)`");
    }
    const Headers = rd.headers;
    const Query = rd.query;
    const Params = rd.params;
    const param_names = routeParamNames(rd.pattern);
    const MwStaticCtx = ServerT.RouteStaticType(route_index);
    const CtxPtr = @FieldType(ServerT, "ctx");
    const HeaderLookup = parse.Lookup(Headers, .header);
    const QueryLookup = parse.Lookup(Query, .query);

    const ParamsEffective = comptime blk: {
        const Provided = Params;
        const ProvidedFields = parse.structFields(Provided);

        // Disallow declaring params not present in the route pattern.
        for (ProvidedFields) |f| {
            var found = false;
            for (param_names) |pn| {
                if (std.mem.eql(u8, pn, f.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                @compileError("params field '" ++ f.name ++ "' is not present in the route pattern");
            }
        }

        // Default any undeclared route params to strings.
        if (param_names.len == 0) break :blk Provided;
        var names: [param_names.len][]const u8 = undefined;
        var types: [param_names.len]type = undefined;
        var attrs: [param_names.len]std.builtin.Type.StructField.Attributes = undefined;
        for (&attrs) |*a| a.* = .{};
        for (param_names, 0..) |pn, i| {
            names[i] = pn;
            types[i] = if (@hasField(Provided, pn)) @FieldType(Provided, pn) else parse.PathString;
        }
        break :blk @Struct(.auto, null, names[0..], &types, &attrs);
    };

    return struct {
        pub const path: []const u8 = rd.pattern;
        pub const method: []const u8 = rd.method;
        _base: Base,
        _server: ServerPtr,
        _mw_ctx: MwCtx,
        _headers: Headers = parse.emptyStruct(Headers),
        _query: Query = parse.emptyStruct(Query),
        _params: ParamsEffective = parse.emptyStruct(ParamsEffective),

        const Self = @This();
        var default_server: ServerT = undefined;
        var default_reader_buf: [0]u8 = .{};
        var default_reader: Io.Reader = Io.Reader.fixed(default_reader_buf[0..]);
        var default_writer_buf: [0]u8 = .{};
        var default_writer: Io.Writer = Io.Writer.fixed(default_writer_buf[0..]);

        pub const ParamNames: []const []const u8 = param_names;

        pub fn initWithServer(
            init_arena: Allocator,
            line: RequestLine,
            mw_ctx: MwCtx,
            srv: ServerPtr,
        ) Self {
            return .{
                ._base = .{
                    .arena = init_arena,
                    .reader = &default_reader,
                    .writer = &default_writer,
                    .version = line.version,
                },
                ._server = srv,
                ._mw_ctx = mw_ctx,
            };
        }

        pub fn initWithCtx(
            init_arena: Allocator,
            init_io: Io,
            line: RequestLine,
            mw_ctx: MwCtx,
            app_ctx: CtxPtr,
        ) Self {
            default_server = undefined;
            default_server.io = init_io;
            default_server.gpa = init_arena;
            default_server.ctx = app_ctx;
            default_server.routeStatic(route_index).* = std.mem.zeroes(MwStaticCtx);
            return initWithServer(init_arena, line, mw_ctx, &default_server);
        }

        /// Initializes this value.
        pub fn init(init_arena: Allocator, init_io: Io, line: RequestLine, mw_ctx: MwCtx) Self {
            if (CtxPtr != void) @compileError("Request.init requires void app context; use initWithCtx for non-void context");
            return initWithCtx(init_arena, init_io, line, mw_ctx, {});
        }

        pub fn ctx(self: *Self) CtxPtr {
            return self._server.ctx;
        }

        pub fn ctxConst(self: *const Self) CtxPtr {
            return self._server.ctx;
        }

        pub fn allocator(self: *const Self) Allocator {
            return self._base.arena;
        }

        /// Returns the server GPA.
        ///
        /// Warning: memory allocated with this allocator is not request-owned
        /// and must be freed manually by the caller.
        pub fn gpa(self: *const Self) Allocator {
            return self._server.gpa;
        }

        pub fn base(self: *Self) *Base {
            return &self._base;
        }

        pub fn baseConst(self: *const Self) *const Base {
            return &self._base;
        }

        pub fn io(self: *const Self) Io {
            return self._server.io;
        }

        pub fn reader(self: *const Self) *Io.Reader {
            return self._base.reader;
        }

        pub fn writer(self: *const Self) *Io.Writer {
            return self._base.writer;
        }

        /// Returns the owning server pointer for this request.
        pub fn server(self: *const Self) ServerPtr {
            return self._server;
        }

        pub fn mwCtxMut(self: *Self) *MwCtx {
            return &self._mw_ctx;
        }

        pub fn mwCtxConst(self: *const Self) *const MwCtx {
            return &self._mw_ctx;
        }

        pub fn mwStaticCtxMut(self: *Self) *MwStaticCtx {
            return self._server.routeStatic(route_index);
        }

        pub fn mwStaticCtxConst(self: *const Self) *const MwStaticCtx {
            return self._server.routeStaticConst(route_index);
        }

        pub fn headersMut(self: *Self) *Headers {
            return &self._headers;
        }

        pub fn headersConst(self: *const Self) *const Headers {
            return &self._headers;
        }

        pub fn queryMut(self: *Self) *Query {
            return &self._query;
        }

        pub fn queryConst(self: *const Self) *const Query {
            return &self._query;
        }

        pub fn paramsMut(self: *Self) *ParamsEffective {
            return &self._params;
        }

        pub fn paramsConst(self: *const Self) *const ParamsEffective {
            return &self._params;
        }

        fn framingForContentLength(len: usize) BodyFraming {
            return if (len == 0) .content_length_zero else .content_length;
        }

        fn bodyFraming(body: Body) BodyFraming {
            return switch (body) {
                .none => .none,
                .chunked => .chunked,
                .content_length => |len| framingForContentLength(len),
                .downloaded => |downloaded| downloaded.framing,
                .streamed => |framing| framing,
                .discarded => |framing| framing,
                .errored => |failed| failed.framing,
            };
        }

        fn setDownloadedBody(self: *Self, bytes: []u8, framing: BodyFraming) void {
            self._base.body = .{ .downloaded = .{
                .bytes = bytes,
                .framing = framing,
            } };
        }

        fn setDiscardedBody(self: *Self, framing: BodyFraming) void {
            self._base.body = .{ .discarded = framing };
        }

        fn setStreamedBody(self: *Self, framing: BodyFraming) void {
            self._base.body = .{ .streamed = framing };
        }

        fn clearBody(self: *Self, a: Allocator) void {
            switch (self._base.body) {
                .downloaded => |downloaded| a.free(downloaded.bytes),
                else => {},
            }
            self._base.body = .none;
        }

        /// Releases resources held by this value.
        pub fn deinit(self: *Self, a: Allocator) void {
            self.clearBody(a);
            parse.destroyStruct(&self._headers, a);
            parse.destroyStruct(&self._query, a);
            parse.destroyStruct(&self._params, a);
        }

        /// Get a captured header by field name, e.g. `req.header(.host)`.
        pub fn header(self: *const Self, comptime field: @EnumLiteral()) @TypeOf(@field(self._headers, @tagName(field)).get()) {
            return @field(self._headers, @tagName(field)).get();
        }

        /// Get a captured query param by field name, e.g. `req.queryParam(.page)`.
        pub fn queryParam(self: *const Self, comptime field: @EnumLiteral()) @TypeOf(@field(self._query, @tagName(field)).get()) {
            return @field(self._query, @tagName(field)).get();
        }

        /// Get a typed path param value (declared in endpoint `Info.path` or middleware `Info.path`).
        /// If a route param is not declared, it defaults to a string.
        ///
        /// e.g. `req.paramValue(.id)`.
        pub fn paramValue(self: *const Self, comptime field: @EnumLiteral()) @TypeOf(@field(self._params, @tagName(field)).get()) {
            return @field(self._params, @tagName(field)).get();
        }

        /// Get a pointer to middleware data by name, e.g. `req.middlewareData(.auth)`.
        pub fn middlewareData(self: *Self, comptime name: anytype) *middlewareContextFieldType(MwCtx, name) {
            return &@field(self._mw_ctx, middlewareContextFieldName(MwCtx, name));
        }

        /// Get a const pointer to middleware data by name, e.g. `req.middlewareDataConst(.auth)`.
        pub fn middlewareDataConst(self: *const Self, comptime name: anytype) *const middlewareContextFieldType(MwCtx, name) {
            return &@field(self._mw_ctx, middlewareContextFieldName(MwCtx, name));
        }

        /// Get a pointer to middleware static context by name, e.g. `req.middlewareStatic(.cache)`.
        pub fn middlewareStatic(self: *Self, comptime name: anytype) *middlewareContextFieldType(MwStaticCtx, name) {
            return &@field(self.mwStaticCtxMut().*, middlewareContextFieldName(MwStaticCtx, name));
        }

        /// Get a const pointer to middleware static context by name.
        pub fn middlewareStaticConst(self: *const Self, comptime name: anytype) *const middlewareContextFieldType(MwStaticCtx, name) {
            return &@field(self.mwStaticCtxConst().*, middlewareContextFieldName(MwStaticCtx, name));
        }

        pub fn keepAlive(self: *const Self) bool {
            return self._base.version == .http11 and !self._base.connection_close;
        }

        pub fn parseParams(self: *Self, a: Allocator, params_in: []const []u8) !void {
            if (param_names.len == 0) return;
            std.debug.assert(params_in.len == param_names.len);
            // reset captures each request
            parse.destroyStruct(&self._params, a);
            self._params = parse.emptyStruct(ParamsEffective);
            inline for (param_names, 0..) |pn, i| {
                try @field(self._params, pn).parse(a, params_in[i]);
            }
            try parse.doneParsingStruct(&self._params, &([_]bool{true} ** param_names.len));
        }

        pub fn parseQuery(self: *Self, a: Allocator, query_raw: []u8) !void {
            if (QueryLookup.count == 0) return;
            // reset captures each request
            parse.destroyStruct(&self._query, a);
            self._query = parse.emptyStruct(Query);
            var present: [QueryLookup.count]bool = .{false} ** QueryLookup.count;

            var i: usize = 0;
            const q = query_raw;
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
                            try @field(self._query, f.name).parse(a, v);
                            break;
                        }
                    }
                }
            }

            try parse.doneParsingStruct(&self._query, present[0..]);
        }

        pub fn parseHeaders(self: *Self, a: Allocator, r: *Io.Reader, max_header_bytes: usize) ParseHeadersError!void {
            return self.parseHeadersWithLimits(a, r, max_header_bytes, max_header_bytes);
        }

        /// Parse request headers with separate total and per-line size limits.
        pub fn parseHeadersWithLimits(
            self: *Self,
            a: Allocator,
            r: *Io.Reader,
            max_header_bytes: usize,
            max_single_header_bytes: usize,
        ) ParseHeadersError!void {
            self._base.reader = r;
            self._base.connection_close = false;
            self.clearBody(a);
            if (HeaderLookup.count != 0) {
                // reset captures each request
                parse.destroyStruct(&self._headers, a);
                self._headers = parse.emptyStruct(Headers);
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
                total += line0_incl.len;
                if (total > max_header_bytes) return error.HeadersTooLarge;
                if (line0_incl.len > max_single_header_bytes) return error.HeadersTooLarge;

                const line0 = line0_incl[0 .. line0_incl.len - 1];
                const line = trimCR(line0);
                if (line.len == 0) break;

                const col = std.mem.indexOfScalarPos(u8, line, 1, ':') orelse return error.BadRequest;
                const name = line[0..col];
                var value: []const u8 = line[col + 1 ..];
                value = trimSpaces(value);

                if (headerIs(name, "connection")) {
                    if (containsTokenIgnoreCase(value, "close")) self._base.connection_close = true;
                } else if (headerIs(name, "content-length")) {
                    const parsed = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest;
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
                                try @field(self._headers, f.name).parse(a, value);
                                break;
                            }
                        }
                    }
                }
            }

            if (has_chunked and content_length != null) return error.BadRequest;
            if (has_chunked) {
                self._base.body = .chunked;
            } else if (content_length) |cl| {
                self._base.body = .{ .content_length = cl };
            } else {
                self._base.body = .none;
            }

            if (HeaderLookup.count != 0) {
                try parse.doneParsingStruct(&self._headers, present[0..]);
            }
        }

        fn rememberBodyError(self: *Self, err: BodyOpError) BodyOpError {
            const framing = bodyFraming(self._base.body);
            self.clearBody(self._base.arena);
            self._base.body = .{ .errored = .{
                .err = err,
                .framing = framing,
            } };
            return err;
        }

        fn readExact(self: *Self, r: *Io.Reader, buf: []u8) BodyOpError!void {
            r.readSliceAll(buf) catch |err| return self.rememberBodyError(switch (err) {
                error.EndOfStream => error.EndOfStream,
                error.ReadFailed => error.ReadFailed,
            });
        }

        fn readChunkTrailers(self: *Self, r: *Io.Reader) BodyOpError!void {
            while (true) {
                const t0_incl = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
                    error.StreamTooLong => return self.rememberBodyError(error.BadRequest),
                    error.EndOfStream => return self.rememberBodyError(error.EndOfStream),
                    error.ReadFailed => return self.rememberBodyError(error.ReadFailed),
                };
                const t0 = t0_incl[0 .. t0_incl.len - 1];
                const t = trimCR(t0);
                if (t.len == 0) return;
            }
        }

        fn readChunkHeader(self: *Self, r: *Io.Reader) BodyOpError!?usize {
            const line0_incl = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => return self.rememberBodyError(error.BadRequest),
                error.EndOfStream => return self.rememberBodyError(error.EndOfStream),
                error.ReadFailed => return self.rememberBodyError(error.ReadFailed),
            };
            const line0 = line0_incl[0 .. line0_incl.len - 1];
            const line = trimCR(line0);
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
            const size_str = std.mem.trim(u8, line[0..semi], " \t");
            const size = std.fmt.parseInt(usize, size_str, 16) catch return self.rememberBodyError(error.BadRequest);
            if (size == 0) {
                // A zero-sized chunk terminates the body and is followed by
                // optional trailers plus a blank line.
                try self.readChunkTrailers(r);
                return null;
            }
            return size;
        }

        fn readChunkCrlf(self: *Self, r: *Io.Reader) BodyOpError!void {
            var crlf: [2]u8 = undefined;
            try self.readExact(r, crlf[0..]);
            if (crlf[0] != '\r' or crlf[1] != '\n') return self.rememberBodyError(error.BadRequest);
        }

        fn readContentLengthAll(self: *Self, a: Allocator, r: *Io.Reader, len: usize, max_bytes: usize) BodyOpError![]const u8 {
            if (len > max_bytes) return self.rememberBodyError(error.PayloadTooLarge);
            const buf = try a.alloc(u8, len);
            errdefer a.free(buf);
            try self.readExact(r, buf);
            self.setDownloadedBody(buf, framingForContentLength(len));
            return buf;
        }

        fn readChunkedAll(self: *Self, a: Allocator, r: *Io.Reader, max_bytes: usize) BodyOpError![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(a);
            while (try self.readChunkHeader(r)) |size| {
                const start = out.items.len;
                if (size > max_bytes or start > max_bytes - size) return self.rememberBodyError(error.PayloadTooLarge);
                try out.resize(a, start + size);
                try self.readExact(r, out.items[start..][0..size]);
                try self.readChunkCrlf(r);
            }
            const body = try out.toOwnedSlice(a);
            self.setDownloadedBody(body, .chunked);
            return body;
        }

        pub const BodyReader = struct {
            req: *Self,
            reader: *Io.Reader,
            framing: BodyFraming,
            state: union(enum) {
                done,
                none,
                content_length: usize,
                chunked: usize,
            },

            fn finish(self: *@This()) void {
                // Streaming consumes ownership of the remaining body bytes. Once
                // the stream reaches EOF there is nothing left for keep-alive
                // cleanup to discard, so the request moves to `.discarded`.
                self.req.setDiscardedBody(self.framing);
                self.state = .done;
            }

            /// Reads the next body bytes into `buf`, returning `0` at body EOF.
            pub fn read(self: *@This(), buf: []u8) BodyOpError!usize {
                if (buf.len == 0) return 0;

                switch (self.state) {
                    .done => return 0,
                    .none => {
                        self.finish();
                        return 0;
                    },
                    .content_length => |*remaining| {
                        if (remaining.* == 0) {
                            self.finish();
                            return 0;
                        }
                        const want = @min(remaining.*, buf.len);
                        var parts = [_][]u8{buf[0..want]};
                        const n = self.reader.readVec(parts[0..]) catch |err| return self.req.rememberBodyError(switch (err) {
                            error.EndOfStream => error.EndOfStream,
                            error.ReadFailed => error.ReadFailed,
                        });
                        remaining.* -= n;
                        if (remaining.* == 0) self.finish();
                        return n;
                    },
                    .chunked => |*chunk_remaining| {
                        while (true) {
                            if (chunk_remaining.* == 0) {
                                if (try self.req.readChunkHeader(self.reader)) |size| {
                                    chunk_remaining.* = size;
                                } else {
                                    self.finish();
                                    return 0;
                                }
                            }
                            const want = @min(chunk_remaining.*, buf.len);
                            var parts = [_][]u8{buf[0..want]};
                            const n = self.reader.readVec(parts[0..]) catch |err| return self.req.rememberBodyError(switch (err) {
                                error.EndOfStream => error.EndOfStream,
                                error.ReadFailed => error.ReadFailed,
                            });
                            chunk_remaining.* -= n;
                            if (chunk_remaining.* == 0) try self.req.readChunkCrlf(self.reader);
                            return n;
                        }
                    },
                }
            }

            /// Reads the remaining body bytes into request-owned storage.
            pub fn readAll(self: *@This(), a: Allocator, max_bytes: usize) BodyOpError![]const u8 {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(a);
                var buf: [1024]u8 = undefined;
                while (true) {
                    const n = try self.read(buf[0..]);
                    if (n == 0) break;
                    if (out.items.len > max_bytes -| n) return self.req.rememberBodyError(error.PayloadTooLarge);
                    try out.appendSlice(a, buf[0..n]);
                }
                const body = try out.toOwnedSlice(a);
                self.req.clearBody(a);
                self.req.setDownloadedBody(body, self.framing);
                self.state = .done;
                return body;
            }

            /// Discards any unread bytes remaining in this body stream.
            pub fn discardRemaining(self: *@This()) BodyOpError!void {
                switch (self.state) {
                    .done => return,
                    .none => {
                        self.finish();
                        return;
                    },
                    .content_length => |remaining| {
                        var unread = remaining;
                        while (unread != 0) {
                            const tossed = self.reader.discard(.limited(unread)) catch |err| return self.req.rememberBodyError(switch (err) {
                                error.EndOfStream => error.EndOfStream,
                                error.ReadFailed => error.ReadFailed,
                            });
                            unread -= tossed;
                        }
                        self.finish();
                    },
                    .chunked => |remaining| {
                        var unread = remaining;
                        while (unread != 0) {
                            const tossed = self.reader.discard(.limited(unread)) catch |err| return self.req.rememberBodyError(switch (err) {
                                error.EndOfStream => error.EndOfStream,
                                error.ReadFailed => error.ReadFailed,
                            });
                            unread -= tossed;
                        }
                        if (remaining != 0) try self.req.readChunkCrlf(self.reader);
                        while (try self.req.readChunkHeader(self.reader)) |size| {
                            var chunk_unread = size;
                            while (chunk_unread != 0) {
                                const tossed = self.reader.discard(.limited(chunk_unread)) catch |err| return self.req.rememberBodyError(switch (err) {
                                    error.EndOfStream => error.EndOfStream,
                                    error.ReadFailed => error.ReadFailed,
                                });
                                chunk_unread -= tossed;
                            }
                            try self.req.readChunkCrlf(self.reader);
                        }
                        self.finish();
                    },
                }
            }
        };

        /// Read and return the full request body, up to `max_bytes`.
        pub fn bodyAll(self: *Self, max_bytes: usize) BodyOpError![]const u8 {
            return switch (self._base.body) {
                .none => "",
                .content_length => |len| self.readContentLengthAll(self._base.arena, self._base.reader, len, max_bytes),
                .chunked => self.readChunkedAll(self._base.arena, self._base.reader, max_bytes),
                .downloaded => |downloaded| downloaded.bytes,
                .discarded, .streamed => error.BadRequest,
                .errored => |failed| failed.err,
            };
        }

        /// Starts streaming the request body.
        pub fn bodyReader(self: *Self) BodyOpError!BodyReader {
            return switch (self._base.body) {
                .none => blk: {
                    self.setStreamedBody(.none);
                    break :blk .{
                        .req = self,
                        .reader = self._base.reader,
                        .framing = .none,
                        .state = .none,
                    };
                },
                .content_length => |len| blk: {
                    const framing = framingForContentLength(len);
                    self.setStreamedBody(framing);
                    break :blk .{
                        .req = self,
                        .reader = self._base.reader,
                        .framing = framing,
                        .state = .{ .content_length = len },
                    };
                },
                .chunked => blk: {
                    self.setStreamedBody(.chunked);
                    break :blk .{
                        .req = self,
                        .reader = self._base.reader,
                        .framing = .chunked,
                        .state = .{ .chunked = 0 },
                    };
                },
                .downloaded, .discarded, .streamed => error.BadRequest,
                .errored => |failed| failed.err,
            };
        }

        /// Discard any unread request body bytes so the connection can be reused.
        pub fn discardUnreadBody(self: *Self) BodyOpError!void {
            switch (self._base.body) {
                .none, .downloaded, .discarded => return,
                .content_length => |len| {
                    var remaining = len;
                    while (remaining != 0) {
                        const tossed = self._base.reader.discard(.limited(remaining)) catch |err| return self.rememberBodyError(switch (err) {
                            error.EndOfStream => error.EndOfStream,
                            error.ReadFailed => error.ReadFailed,
                        });
                        remaining -= tossed;
                    }
                    self.setDiscardedBody(framingForContentLength(len));
                },
                .chunked => {
                    while (try self.readChunkHeader(self._base.reader)) |size| {
                        var remaining = size;
                        while (remaining != 0) {
                            const tossed = self._base.reader.discard(.limited(remaining)) catch |err| return self.rememberBodyError(switch (err) {
                                error.EndOfStream => error.EndOfStream,
                                error.ReadFailed => error.ReadFailed,
                            });
                            remaining -= tossed;
                        }
                        try self.readChunkCrlf(self._base.reader);
                    }
                    self.setDiscardedBody(.chunked);
                },
                .streamed => return error.BadRequest,
                .errored => |failed| return failed.err,
            }
        }
    };
}

/// Build a synthetic route pattern for standalone request test types that only
/// know their param names and not a full `RouteDecl`.
fn syntheticPatternFromParamNames(comptime param_names: []const []const u8) []const u8 {
    if (param_names.len == 0) return "/";
    comptime var out: []const u8 = "";
    inline for (param_names) |pn| {
        out = out ++ "/{" ++ pn ++ "}";
    }
    return out;
}

pub fn Request(comptime Headers: type, comptime Query: type, comptime param_names: []const []const u8, comptime MwCtx: type) type {
    const route_pattern = syntheticPatternFromParamNames(param_names);
    const rd: route_decl.RouteDecl = .{
        .method = "GET",
        .pattern = route_pattern,
        .endpoint = struct {},
        .headers = Headers,
        .query = Query,
        .params = struct {},
        .middlewares = &.{},
        .operations = &.{},
    };
    const StandaloneServer = struct {
        const RouteStaticCtx = struct {};
        io: Io,
        gpa: Allocator,
        ctx: void,
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
    };
    return RequestPWithPatternExt(*StandaloneServer, 0, rd, MwCtx);
}

const TestMwCtx = struct {};

test "query capture + decode" {
    const ReqT = Request(
        struct {},
        struct {
            name: parse.Optional(parse.String),
            page: parse.Optional(parse.Int(u32)),
        },
        &.{},
        TestMwCtx,
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "name=alice%20bob&page=10");
    defer gpa.free(query);

    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    try reqv.parseQuery(gpa, line.query);
    try std.testing.expectEqualStrings("alice bob", reqv.queryParam(.name).?);
    try std.testing.expectEqual(@as(u32, 10), reqv.queryParam(.page).?);
}

test "header capture required vs optional" {
    const ReqOpt = Request(
        struct { host: parse.Optional(parse.String) },
        struct {},
        &.{},
        TestMwCtx,
    );
    const ReqReq = Request(
        struct { host: parse.String },
        struct {},
        &.{},
        TestMwCtx,
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };

    {
        var r = Io.Reader.fixed("User-Agent: x\r\n\r\n");
        const mw_ctx: TestMwCtx = .{};
        var reqv = ReqOpt.init(gpa, std.testing.io, line, mw_ctx);
        defer reqv.deinit(gpa);
        try reqv.parseHeaders(gpa, &r, 1024);
        try std.testing.expect(reqv.header(.host) == null);
    }

    {
        var r = Io.Reader.fixed("User-Agent: x\r\n\r\n");
        const mw_ctx: TestMwCtx = .{};
        var reqv = ReqReq.init(gpa, std.testing.io, line, mw_ctx);
        defer reqv.deinit(gpa);
        try std.testing.expectError(error.MissingRequired, reqv.parseHeaders(gpa, &r, 1024));
    }
}

test "chunked bodyAll" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n0\r\n\r\n");
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    try reqv.parseHeaders(gpa, &r, 1024);
    const body = try reqv.bodyAll(32);
    try std.testing.expectEqualStrings("Wiki", body);
}

test "chunked bodyAll: max_bytes enforced" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n");
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    try reqv.parseHeaders(gpa, &r, 1024);
    try std.testing.expectError(error.PayloadTooLarge, reqv.bodyAll(4));
}

test "request line: borrowed parses path/query" {
    var r = Io.Reader.fixed("GET /a/b?x=1 HTTP/1.1\r\n");
    const line = try parseRequestLineBorrowed(&r, 8 * 1024);
    try std.testing.expectEqualStrings("GET", line.method);
    try std.testing.expectEqual(Version.http11, line.version);
    try std.testing.expectEqualStrings("/a/b", line.path);
    try std.testing.expectEqualStrings("x=1", line.query);
}

test "request line: rejects non-absolute path target" {
    var r = Io.Reader.fixed("GET http://example.com/ HTTP/1.1\r\n");
    try std.testing.expectError(error.BadRequest, parseRequestLineBorrowed(&r, 8 * 1024));
}

test "request line: max length enforced" {
    var r = Io.Reader.fixed("GET /abcd HTTP/1.1\r\n");
    try std.testing.expectError(error.UriTooLong, parseRequestLineBorrowed(&r, 4));
}

test "headers: underscore field matches dash header" {
    const ReqT = Request(
        struct {
            content_type: parse.Optional(parse.String),
        },
        struct {},
        &.{},
        TestMwCtx,
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Type: text/plain\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectEqualStrings("text/plain", reqv.header(.content_type).?);
}

test "headers: too large rejected" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("X: 1234567890\r\n\r\n");
    try std.testing.expectError(error.HeadersTooLarge, reqv.parseHeaders(gpa, &r, 8));
}

test "headers: parseHeadersWithLimits enforces per-line limit independently" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var too_long = Io.Reader.fixed("X-Long: 1234567890\r\n\r\n");
    try std.testing.expectError(error.HeadersTooLarge, reqv.parseHeadersWithLimits(gpa, &too_long, 128, 12));

    var ok = Io.Reader.fixed("X: 1234\r\n\r\n");
    try reqv.parseHeadersWithLimits(gpa, &ok, 128, 12);
}

test "headers: duplicate Content-Length mismatch rejected" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Length: 1\r\nContent-Length: 2\r\n\r\n");
    try std.testing.expectError(error.BadRequest, reqv.parseHeaders(gpa, &r, 8 * 1024));
}

test "headers: chunked + Content-Length rejected" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n");
    try std.testing.expectError(error.BadRequest, reqv.parseHeaders(gpa, &r, 8 * 1024));
}

test "headers: Connection close disables keep-alive" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Connection: keep-alive, Close\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expect(!reqv.keepAlive());
}

test "headers: HTTP/1.0 is never keep-alive in current policy" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;

    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http10, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Connection: keep-alive\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expect(!reqv.keepAlive());
}

test "headers: trim value + case-insensitive match" {
    const ReqT = Request(
        struct { host: parse.Optional(parse.String) },
        struct {},
        &.{},
        TestMwCtx,
    );
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("hOsT:\t  example.com \t\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectEqualStrings("example.com", reqv.header(.host).?);
}

test "headers: transfer-encoding list sets chunked" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Transfer-Encoding: gzip, chunked\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectEqualDeep(Body{ .chunked = {} }, reqv.baseConst().body);
}

test "headers: transfer-encoding token match is case-insensitive" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Transfer-Encoding: GZIP, CHUNKED\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectEqualDeep(Body{ .chunked = {} }, reqv.baseConst().body);
}

test "chunked: invalid chunk CRLF rejected" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n1\r\naXY0\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectError(error.BadRequest, reqv.discardUnreadBody());
}

test "chunked: truncated body yields EndOfStream" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n1\r\na");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectError(error.EndOfStream, reqv.discardUnreadBody());
}

test "bodyAll: content-length" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    const body = try reqv.bodyAll(16);
    try std.testing.expectEqualStrings("hello", body);
    try std.testing.expectEqualStrings("hello", switch (reqv.baseConst().body) {
        .downloaded => |cached| cached.bytes,
        else => unreachable,
    });
}

test "headers: content-length zero stays distinct from no body" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Length: 0\r\n\r\n");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectEqualDeep(Body{ .content_length = 0 }, reqv.baseConst().body);
    const body = try reqv.bodyAll(0);
    try std.testing.expectEqualStrings("", body);
    try std.testing.expectEqualStrings("", switch (reqv.baseConst().body) {
        .downloaded => |cached| cached.bytes,
        else => unreachable,
    });
    try std.testing.expectEqualDeep(Body{ .downloaded = .{
        .bytes = "",
        .framing = .content_length_zero,
    } }, reqv.baseConst().body);
}

test "bodyAll: does not emit interim 100-continue by itself" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    var out: [128]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    reqv.base().writer = &w;

    const body = try reqv.bodyAll(16);
    try std.testing.expectEqualStrings("hello", body);
    try std.testing.expectEqual(@as(usize, 0), w.end);

    const cached = try reqv.bodyAll(16);
    try std.testing.expectEqualStrings("hello", cached);
    try std.testing.expectEqual(@as(usize, 0), w.end);
}

test "bodyAll: max_bytes enforced" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectError(error.PayloadTooLarge, reqv.bodyAll(4));
}

test "discardUnreadBody: does not emit interim 100-continue by itself" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    var out: [128]u8 = undefined;
    var w = Io.Writer.fixed(out[0..]);
    reqv.base().writer = &w;

    try reqv.discardUnreadBody();
    try std.testing.expectEqual(@as(usize, 0), w.end);
}

test "bodyReader: readAll caches downloaded body" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    var br = try reqv.bodyReader();
    const body = try br.readAll(gpa, 16);
    try std.testing.expectEqualStrings("hello", body);
    try std.testing.expectEqualStrings("hello", try reqv.bodyAll(16));
}

test "bodyReader: partial stream then discard transitions to discarded" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    var br = try reqv.bodyReader();
    var buf: [2]u8 = undefined;
    const n = try br.read(buf[0..]);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("he", buf[0..n]);
    try std.testing.expectEqualDeep(Body{ .streamed = .content_length }, reqv.baseConst().body);
    try br.discardRemaining();
    try std.testing.expectEqualDeep(Body{ .discarded = .content_length }, reqv.baseConst().body);
    try std.testing.expectError(error.BadRequest, reqv.bodyAll(16));
}

test "bodyReader: none body reaches eof immediately and marks discarded" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, std.testing.io, line, .{});
    defer reqv.deinit(gpa);

    var br = try reqv.bodyReader();
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try br.read(buf[0..]));
    try std.testing.expectEqualDeep(Body{ .discarded = .none }, reqv.baseConst().body);
}

test "bodyReader: content-length zero reaches eof immediately and marks discarded" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };
    var reqv = ReqT.init(gpa, std.testing.io, line, .{});
    defer reqv.deinit(gpa);
    reqv.base().body = .{ .content_length = 0 };

    var br = try reqv.bodyReader();
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try br.read(buf[0..]));
    try std.testing.expectEqualDeep(Body{ .discarded = .content_length_zero }, reqv.baseConst().body);
}

test "bodyAll: replays stored body error" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    var r = Io.Reader.fixed("Content-Length: 5\r\n\r\nhel");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectError(error.EndOfStream, reqv.bodyAll(16));
    try std.testing.expectEqualDeep(Body{ .errored = .{
        .err = error.EndOfStream,
        .framing = .content_length,
    } }, reqv.baseConst().body);
    try std.testing.expectError(error.EndOfStream, reqv.bodyAll(16));
    try std.testing.expectError(error.EndOfStream, reqv.discardUnreadBody());
}

test "query: required missing rejected" {
    const ReqT = Request(
        struct {},
        struct {
            q: parse.String,
        },
        &.{},
        TestMwCtx,
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    try std.testing.expectError(error.MissingRequired, reqv.parseQuery(gpa, line.query));
}

test "query: invalid percent-encoding rejected" {
    const ReqT = Request(
        struct {},
        struct {
            name: parse.Optional(parse.String),
        },
        &.{},
        TestMwCtx,
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "name=%ZZ");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    try std.testing.expectError(error.InvalidPercentEncoding, reqv.parseQuery(gpa, line.query));
}

test "query: repeated keys last-wins, SliceOf collects" {
    const ReqLast = Request(
        struct {},
        struct { k: parse.Optional(parse.String) },
        &.{},
        TestMwCtx,
    );
    const ReqList = Request(
        struct {},
        struct { k: parse.SliceOf(parse.String) },
        &.{},
        TestMwCtx,
    );

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);

    {
        const query = try gpa.dupe(u8, "k=one&k=two");
        defer gpa.free(query);
        const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };
        const mw_ctx: TestMwCtx = .{};
        var reqv = ReqLast.init(gpa, std.testing.io, line, mw_ctx);
        defer reqv.deinit(gpa);
        try reqv.parseQuery(gpa, line.query);
        try std.testing.expectEqualStrings("two", reqv.queryParam(.k).?);
    }

    {
        const query = try gpa.dupe(u8, "k=one&k=two");
        defer gpa.free(query);
        const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };
        const mw_ctx: TestMwCtx = .{};
        var reqv = ReqList.init(gpa, std.testing.io, line, mw_ctx);
        defer reqv.deinit(gpa);
        try reqv.parseQuery(gpa, line.query);
        const items = reqv.queryParam(.k);
        try std.testing.expectEqual(@as(usize, 2), items.len);
        try std.testing.expectEqualStrings("one", items[0].get());
        try std.testing.expectEqualStrings("two", items[1].get());
    }
}

test "parseHeaders: rejects header line without colon" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("NoColon\r\n\r\n");
    try std.testing.expectError(error.BadRequest, reqv.parseHeaders(gpa, &r, 8 * 1024));
}

test "parseHeaders: repeated Content-Length same value accepted" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Content-Length: 2\r\nContent-Length: 2\r\n\r\nok");
    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    const body = try reqv.bodyAll(8);
    try std.testing.expectEqualStrings("ok", body);
}

test "parseHeaders: resets connection/body state between parses" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);

    {
        var r = Io.Reader.fixed("Connection: close\r\nContent-Length: 4\r\n\r\ntest");
        try reqv.parseHeaders(gpa, &r, 8 * 1024);
        try std.testing.expect(!reqv.keepAlive());
        try std.testing.expectEqualDeep(Body{ .content_length = 4 }, reqv.baseConst().body);
        const body = try reqv.bodyAll(8);
        try std.testing.expectEqualStrings("test", body);
    }

    {
        var r = Io.Reader.fixed("\r\n");
        try reqv.parseHeaders(gpa, &r, 8 * 1024);
        try std.testing.expect(reqv.keepAlive());
        try std.testing.expectEqualDeep(Body{ .none = {} }, reqv.baseConst().body);
    }
}

test "parseHeaders: invalid Content-Length rejected" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    var r = Io.Reader.fixed("Content-Length: nope\r\n\r\n");
    try std.testing.expectError(error.BadRequest, reqv.parseHeaders(gpa, &r, 8 * 1024));
}

test "chunked bodyAll: chunk extensions supported" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    var r = Io.Reader.fixed("Transfer-Encoding: chunked\r\n\r\n4;ext=1\r\nWiki\r\n0\r\n\r\n");
    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    try reqv.parseHeaders(gpa, &r, 1024);
    const body = try reqv.bodyAll(32);
    try std.testing.expectEqualStrings("Wiki", body);
}

test "bodyAll/discardUnreadBody: without parseHeaders uses default no-body state" {
    const ReqT = Request(struct {}, struct {}, &.{}, TestMwCtx);
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "POST", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    const body = try reqv.bodyAll(1);
    try std.testing.expectEqualStrings("", body);
    try reqv.discardUnreadBody();
}

test "parseQuery: key without '=' treated as empty value" {
    const ReqT = Request(
        struct {},
        struct { k: parse.Optional(parse.String) },
        &.{},
        TestMwCtx,
    );
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "k");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };

    const mw_ctx: TestMwCtx = .{};
    var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
    defer reqv.deinit(gpa);
    try reqv.parseQuery(gpa, line.query);
    try std.testing.expectEqualStrings("", reqv.queryParam(.k).?);
}

test "RequestPWithPatternExt: accessors, setters, middleware data, and typed captures" {
    const AppCtx = struct {
        value: u8,
    };
    const AuthData = struct {
        value: u8 = 1,
    };
    const StaticData = struct {
        value: u8 = 9,
    };
    const MwCtx = struct {
        auth: AuthData = .{},
    };
    const Server = struct {
        io: Io,
        gpa: Allocator,
        ctx: *AppCtx,
        route_static_ctx: StaticData = .{},

        pub fn RouteStaticType(comptime route_index: usize) type {
            if (route_index != 0) @compileError("route index out of bounds");
            return StaticData;
        }

        pub fn routeStatic(self: *@This(), comptime route_index: usize) *StaticData {
            if (route_index != 0) @compileError("route index out of bounds");
            return &self.route_static_ctx;
        }

        pub fn routeStaticConst(self: *const @This(), comptime route_index: usize) *const StaticData {
            if (route_index != 0) @compileError("route index out of bounds");
            return &self.route_static_ctx;
        }
    };
    const Headers = struct {
        content_length: parse.Optional(parse.Int(usize)),
    };
    const Query = struct {
        page: parse.Optional(parse.Int(u16)),
    };
    const Params = struct {
        id: parse.Int(u32),
    };
    const rd: route_decl.RouteDecl = .{
        .method = "GET",
        .pattern = "/items/{id}",
        .endpoint = struct {},
        .headers = Headers,
        .query = Query,
        .params = Params,
        .middlewares = &.{},
        .operations = &.{},
    };
    const ReqT = RequestPWithPatternExt(*Server, 0, rd, MwCtx);

    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "/items/7");
    defer gpa.free(path);
    const query = try gpa.dupe(u8, "page=42");
    defer gpa.free(query);
    const line: RequestLine = .{ .method = "GET", .version = .http11, .path = path, .query = query };

    var app_ctx: AppCtx = .{ .value = 3 };
    var server: Server = .{ .io = std.testing.io, .gpa = gpa, .ctx = &app_ctx };
    var reqv = ReqT.initWithServer(gpa, line, .{ .auth = .{ .value = 5 } }, &server);
    defer reqv.deinit(gpa);

    try std.testing.expect(reqv.server() == &server);
    try std.testing.expect(reqv.gpa().ptr == gpa.ptr);
    try std.testing.expectEqual(@as(u8, 3), reqv.ctx().value);
    try std.testing.expectEqual(@as(u8, 3), reqv.ctxConst().value);
    reqv.mwCtxMut().auth.value = 6;
    try std.testing.expectEqual(@as(u8, 6), reqv.mwCtxConst().auth.value);
    reqv.middlewareData(.auth).value = 7;
    try std.testing.expectEqual(@as(u8, 7), reqv.middlewareDataConst("auth").value);
    reqv.mwStaticCtxMut().value = 10;
    try std.testing.expectEqual(@as(u8, 10), reqv.mwStaticCtxConst().value);
    reqv.middlewareStatic(.value).* = 11;
    try std.testing.expectEqual(@as(u8, 11), reqv.middlewareStaticConst("value").*);

    var r = Io.Reader.fixed("Content-Length: 5\r\n\r\nhello");
    var out_buf: [64]u8 = undefined;
    var w = Io.Writer.fixed(out_buf[0..]);
    reqv.base().reader = &r;
    reqv.base().writer = &w;
    try std.testing.expect(reqv.reader() == &r);
    try std.testing.expect(reqv.writer() == &w);
    try std.testing.expectEqual(Version.http11, reqv.baseConst().version);
    reqv.base().connection_close = true;
    try std.testing.expect(!reqv.keepAlive());

    const alt_base: Base = .{
        .arena = gpa,
        .reader = &r,
        .writer = &w,
        .version = .http11,
    };
    reqv._base = alt_base;
    reqv._base.arena = gpa;
    try std.testing.expectEqual(Version.http11, reqv.baseConst().version);
    _ = reqv.allocator();
    _ = reqv.io();

    var app_ctx2: AppCtx = .{ .value = 8 };
    reqv._server.ctx = &app_ctx2;
    try std.testing.expectEqual(@as(u8, 8), reqv.ctx().value);
    reqv._mw_ctx = .{ .auth = .{ .value = 12 } };
    try std.testing.expectEqual(@as(u8, 12), reqv.mwCtxConst().auth.value);
    reqv.headersMut().content_length.present = false;
    reqv.queryMut().page.present = false;
    reqv.paramsMut().id.value = 99;
    try std.testing.expect(reqv.headersConst().content_length.get() == null);
    try std.testing.expect(reqv.queryConst().page.get() == null);
    try std.testing.expectEqual(@as(u32, 99), reqv.paramsConst().id.get());

    try reqv.parseQuery(gpa, line.query);
    try std.testing.expectEqual(@as(u16, 42), reqv.queryParam(.page).?);

    var params = [_][]u8{path[path.len - 1 ..]};
    try reqv.parseParams(gpa, params[0..]);
    try std.testing.expectEqual(@as(u32, 7), reqv.paramValue(.id));

    try reqv.parseHeaders(gpa, &r, 8 * 1024);
    try std.testing.expectEqual(@as(usize, 5), reqv.header(.content_length).?);

    const headers_copy = reqv.headersConst().*;
    const query_copy = reqv.queryConst().*;
    const params_copy = reqv.paramsConst().*;
    reqv._headers = headers_copy;
    reqv._query = query_copy;
    reqv._params = params_copy;
    try std.testing.expectEqual(@as(usize, 5), reqv.header(.content_length).?);
    try std.testing.expectEqual(@as(u16, 42), reqv.queryParam(.page).?);
    try std.testing.expectEqual(@as(u32, 7), reqv.paramValue(.id));

    const body = try reqv.bodyAll(8);
    try std.testing.expectEqualStrings("hello", body);

    var server2: Server = .{ .io = std.testing.io, .gpa = gpa, .ctx = &app_ctx2 };
    reqv._server = &server2;
    try std.testing.expect(reqv.server() == &server2);
    try std.testing.expect(reqv.gpa().ptr == gpa.ptr);
    reqv._server.io = std.testing.io;

    var reqv2 = ReqT.initWithCtx(gpa, std.testing.io, line, .{ .auth = .{ .value = 2 } }, &app_ctx2);
    defer reqv2.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 8), reqv2.ctx().value);
}

test "fuzz: parseRequestLineBorrowed" {
    const corpus = &.{
        "GET / HTTP/1.1\r\n",
        "POST /x?y=z HTTP/1.0\r\n",
        "BAD / HTTP/1.1\r\n",
    };
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            var buf: [256]u8 = undefined;
            const max: u16 = @intCast(buf.len);
            const len_u16 = smith.valueRangeAtMost(u16, 1, max);
            const len: usize = @intCast(len_u16);
            smith.bytes(buf[0..len]);
            buf[len - 1] = '\n';
            var r = Io.Reader.fixed(buf[0..len]);
            _ = parseRequestLineBorrowed(&r, 8 * 1024) catch {};
        }
    }.testOne, .{ .corpus = corpus });
}

test "fuzz: parseHeaders" {
    const corpus = &.{
        "Host: example\r\n\r\n",
        "Content-Length: 5\r\n\r\nhello",
        "X:\r\n\r\n",
    };

    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            const ReqT = Request(
                struct {
                    host: parse.Optional(parse.String),
                    content_length: parse.Optional(parse.Int(usize)),
                },
                struct {},
                &.{},
                TestMwCtx,
            );
            const path_buf = "/".*;
            const query_buf: [0]u8 = .{};
            const line: RequestLine = .{
                .method = "GET",
                .version = .http11,
                .path = @constCast(path_buf[0..]),
                .query = @constCast(query_buf[0..]),
            };
            var buf: [256]u8 = undefined;
            const max: u16 = @intCast(buf.len);
            const len_u16 = smith.valueRangeAtMost(u16, 4, max);
            const len: usize = @intCast(len_u16);
            smith.bytes(buf[0..len]);
            buf[len - 4] = '\r';
            buf[len - 3] = '\n';
            buf[len - 2] = '\r';
            buf[len - 1] = '\n';

            const gpa = std.testing.allocator;
            var r1 = Io.Reader.fixed(buf[0..len]);
            const mw_ctx: TestMwCtx = .{};
            var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
            defer reqv.deinit(gpa);
            _ = reqv.parseHeaders(gpa, &r1, 512) catch {};
        }
    }.testOne, .{ .corpus = corpus });
}

test "fuzz: parseQuery" {
    const corpus = &.{
        "q=hello&n=1",
        "k=a&k=b&k=c",
        "q=%ZZ",
    };

    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            const ReqT = Request(
                struct {},
                struct {
                    q: parse.Optional(parse.String),
                    n: parse.Optional(parse.Int(u32)),
                    k: parse.SliceOf(parse.String),
                },
                &.{},
                TestMwCtx,
            );
            const path_buf = "/".*;
            var query_buf: [128]u8 = undefined;
            const max: u16 = @intCast(query_buf.len);
            const len_u16 = smith.valueRangeAtMost(u16, 0, max);
            const len: usize = @intCast(len_u16);
            smith.bytes(query_buf[0..len]);
            const line: RequestLine = .{
                .method = "GET",
                .version = .http11,
                .path = @constCast(path_buf[0..]),
                .query = query_buf[0..len],
            };
            const gpa = std.testing.allocator;
            const mw_ctx: TestMwCtx = .{};
            var reqv = ReqT.init(gpa, std.testing.io, line, mw_ctx);
            defer reqv.deinit(gpa);
            _ = reqv.parseQuery(gpa, line.query) catch {};
        }
    }.testOne, .{ .corpus = corpus });
}
