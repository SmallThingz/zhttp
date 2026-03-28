const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const parse = @import("parse.zig");
const urldecode = @import("urldecode.zig");
const util = @import("util.zig");

pub const Version = enum { http10, http11 };

pub const BodyKind = enum { none, content_length, chunked };

pub const Base = struct {
    /// Stores `io`.
    io: Io,
    /// Stores `arena`.
    arena: Allocator,
    /// Stores `reader`.
    reader: ?*Io.Reader = null,

    /// Stores `version`.
    version: Version,

    /// Stores `connection_close`.
    connection_close: bool = false,

    /// Stores `body_kind`.
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
    /// Stores `method`.
    method: []const u8,
    /// Stores `version`.
    version: Version,
    /// Stores `path`.
    path: []u8,
    /// Stores `query`.
    query: []u8,
};

/// Implements parse request line borrowed.
pub fn parseRequestLineBorrowed(r: *Io.Reader, max_line_len: usize) ParseLineError!RequestLine {
    var line0_incl: []u8 = undefined;
    const available = r.peekGreedy(1) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.ReadFailed => return error.ReadFailed,
    };
    if (available.len == 0) return error.EndOfStream;
    if (std.mem.indexOfScalar(u8, available, '\n')) |nl| {
        line0_incl = available[0 .. nl + 1];
        r.toss(nl + 1);
    } else {
        line0_incl = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.StreamTooLong => return error.UriTooLong,
            error.ReadFailed => return error.ReadFailed,
        };
    }
    if (line0_incl.len == 0) return error.BadRequest;
    var end: usize = line0_incl.len - 1; // strip '\n'
    if (end > max_line_len) return error.UriTooLong;
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

/// Implements parse request line.
pub fn parseRequestLine(r: *Io.Reader, allocator: Allocator, max_line_len: usize) ParseLineError!RequestLine {
    const borrowed = try parseRequestLineBorrowed(r, max_line_len);
    const method_copy = try allocator.dupe(u8, borrowed.method);
    const path = try allocator.dupe(u8, borrowed.path);
    const query = try allocator.dupe(u8, borrowed.query);

    return .{
        .method = method_copy,
        .version = borrowed.version,
        .path = path,
        .query = query,
    };
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

fn RequestPWithPatternExt(
    comptime Headers: type,
    comptime Query: type,
    comptime Params: type,
    comptime param_names: []const []const u8,
    comptime MwCtx: type,
    comptime MwStaticCtx: type,
    comptime route_pattern: []const u8,
    comptime method_name: []const u8,
    comptime CtxPtr: type,
) type {
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
        pub const path: []const u8 = route_pattern;
        pub const method: []const u8 = method_name;
        /// Stores internal `_base` state.
        _base: Base,
        /// Stores internal `_path` state.
        _path: []u8,
        /// Stores internal `_ctx` state.
        _ctx: CtxPtr,
        /// Stores internal `_mw_ctx` state.
        _mw_ctx: MwCtx,
        /// Stores internal `_mw_static_ctx` state.
        _mw_static_ctx: *MwStaticCtx,
        /// Stores internal `_headers` state.
        _headers: Headers = parse.emptyStruct(Headers),
        /// Stores internal `_query` state.
        _query: Query = parse.emptyStruct(Query),
        /// Stores internal `_params` state.
        _params: ParamsEffective = parse.emptyStruct(ParamsEffective),

        const Self = @This();
        var default_mw_static_ctx: MwStaticCtx = std.mem.zeroes(MwStaticCtx);

        pub const ParamNames: []const []const u8 = param_names;

        /// Implements init with ctx.
        pub fn initWithCtx(
            init_arena: Allocator,
            init_io: Io,
            line: RequestLine,
            mw_ctx: MwCtx,
            app_ctx: CtxPtr,
            mw_static_ctx: ?*MwStaticCtx,
        ) Self {
            return .{
                ._base = .{
                    .io = init_io,
                    .arena = init_arena,
                    .version = line.version,
                },
                ._path = line.path,
                ._ctx = app_ctx,
                ._mw_ctx = mw_ctx,
                ._mw_static_ctx = mw_static_ctx orelse &default_mw_static_ctx,
            };
        }

        /// Initializes this value.
        pub fn init(init_arena: Allocator, init_io: Io, line: RequestLine, mw_ctx: MwCtx) Self {
            if (CtxPtr != void) @compileError("Request.init requires void app context; use initWithCtx for non-void context");
            return initWithCtx(init_arena, init_io, line, mw_ctx, {}, null);
        }

        /// Implements ctx.
        pub fn ctx(self: *Self) CtxPtr {
            return self._ctx;
        }

        /// Implements ctx const.
        pub fn ctxConst(self: *const Self) CtxPtr {
            return self._ctx;
        }

        /// Implements set ctx.
        pub fn setCtx(self: *Self, value: CtxPtr) void {
            self._ctx = value;
        }

        /// Implements allocator.
        pub fn allocator(self: *const Self) Allocator {
            return self._base.arena;
        }

        /// Implements base.
        pub fn base(self: *Self) *Base {
            return &self._base;
        }

        /// Implements base const.
        pub fn baseConst(self: *const Self) *const Base {
            return &self._base;
        }

        /// Implements set base.
        pub fn setBase(self: *Self, value: Base) void {
            self._base = value;
        }

        /// Implements io.
        pub fn io(self: *const Self) Io {
            return self._base.io;
        }

        /// Implements set io.
        pub fn setIo(self: *Self, value: Io) void {
            self._base.io = value;
        }

        /// Implements arena.
        pub fn arena(self: *const Self) Allocator {
            return self._base.arena;
        }

        /// Implements set arena.
        pub fn setArena(self: *Self, value: Allocator) void {
            self._base.arena = value;
        }

        /// Implements reader.
        pub fn reader(self: *const Self) ?*Io.Reader {
            return self._base.reader;
        }

        /// Implements set reader.
        pub fn setReader(self: *Self, value: ?*Io.Reader) void {
            self._base.reader = value;
        }

        /// Implements mw ctx mut.
        pub fn mwCtxMut(self: *Self) *MwCtx {
            return &self._mw_ctx;
        }

        /// Implements mw ctx const.
        pub fn mwCtxConst(self: *const Self) *const MwCtx {
            return &self._mw_ctx;
        }

        /// Implements set mw ctx.
        pub fn setMwCtx(self: *Self, value: MwCtx) void {
            self._mw_ctx = value;
        }

        /// Implements mw static ctx mut.
        pub fn mwStaticCtxMut(self: *Self) *MwStaticCtx {
            return self._mw_static_ctx;
        }

        /// Implements mw static ctx const.
        pub fn mwStaticCtxConst(self: *const Self) *const MwStaticCtx {
            return self._mw_static_ctx;
        }

        /// Implements set mw static ctx.
        pub fn setMwStaticCtx(self: *Self, value: *MwStaticCtx) void {
            self._mw_static_ctx = value;
        }

        /// Implements headers mut.
        pub fn headersMut(self: *Self) *Headers {
            return &self._headers;
        }

        /// Implements headers const.
        pub fn headersConst(self: *const Self) *const Headers {
            return &self._headers;
        }

        /// Implements set headers.
        pub fn setHeaders(self: *Self, value: Headers) void {
            self._headers = value;
        }

        /// Implements query mut.
        pub fn queryMut(self: *Self) *Query {
            return &self._query;
        }

        /// Implements query const.
        pub fn queryConst(self: *const Self) *const Query {
            return &self._query;
        }

        /// Implements set query.
        pub fn setQuery(self: *Self, value: Query) void {
            self._query = value;
        }

        /// Implements params mut.
        pub fn paramsMut(self: *Self) *ParamsEffective {
            return &self._params;
        }

        /// Implements params const.
        pub fn paramsConst(self: *const Self) *const ParamsEffective {
            return &self._params;
        }

        /// Implements set params.
        pub fn setParams(self: *Self, value: ParamsEffective) void {
            self._params = value;
        }

        /// Releases resources held by this value.
        pub fn deinit(self: *Self, a: Allocator) void {
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
            return &@field(self._mw_static_ctx.*, middlewareContextFieldName(MwStaticCtx, name));
        }

        /// Get a const pointer to middleware static context by name.
        pub fn middlewareStaticConst(self: *const Self, comptime name: anytype) *const middlewareContextFieldType(MwStaticCtx, name) {
            return &@field(self._mw_static_ctx.*, middlewareContextFieldName(MwStaticCtx, name));
        }

        /// Implements keep alive.
        pub fn keepAlive(self: *const Self) bool {
            return self._base.version == .http11 and !self._base.connection_close;
        }

        /// Implements raw path.
        pub fn rawPath(self: *const Self) []const u8 {
            return self._path;
        }

        /// Implements parse params.
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

        /// Implements parse query.
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

        /// Implements parse headers.
        pub fn parseHeaders(self: *Self, a: Allocator, r: *Io.Reader, max_header_bytes: usize) ParseHeadersError!void {
            self._base.reader = r;
            if (HeaderLookup.count != 0) {
                // reset captures each request
                parse.destroyStruct(&self._headers, a);
                self._headers = parse.emptyStruct(Headers);
            }
            var present: [HeaderLookup.count]bool = .{false} ** HeaderLookup.count;

            var total: usize = 0;
            var content_length: ?usize = null;
            var has_chunked: bool = false;

            // Fast path: empty header section.
            const peek = r.peekGreedy(2) catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return error.ReadFailed,
            };
            if (peek.len >= 2 and peek[0] == '\r' and peek[1] == '\n') {
                r.toss(2);
                self._base.body_kind = .none;
                self._base.body_remaining = 0;
                if (HeaderLookup.count != 0) {
                    try parse.doneParsingStruct(&self._headers, present[0..]);
                }
                return;
            }

            var line_buf: std.ArrayList(u8) = undefined;
            var line_buf_inited: bool = false;
            defer if (line_buf_inited) line_buf.deinit(a);
            var in_accum: bool = false;
            var done: bool = false;

            while (!done) {
                const available = r.peekGreedy(1) catch |err| switch (err) {
                    error.EndOfStream => return error.EndOfStream,
                    error.ReadFailed => return error.ReadFailed,
                };
                if (available.len == 0) return error.EndOfStream;

                var line_start: usize = 0;
                var search_pos: usize = 0;
                while (true) {
                    const nl = std.mem.indexOfScalarPos(u8, available, search_pos, '\n') orelse break;
                    total += (nl - line_start + 1);
                    if (total > max_header_bytes) return error.HeadersTooLarge;

                    const seg = available[line_start..nl];
                    var line: []const u8 = undefined;
                    if (in_accum) {
                        try line_buf.appendSlice(a, seg);
                        if (line_buf.items.len != 0 and line_buf.items[line_buf.items.len - 1] == '\r') {
                            line_buf.items.len -= 1;
                        }
                        line = line_buf.items;
                    } else {
                        line = seg;
                        if (line.len != 0 and line[line.len - 1] == '\r') {
                            line = line[0 .. line.len - 1];
                        }
                    }
                    if (line.len == 0) {
                        r.toss(nl + 1);
                        done = true;
                        break;
                    }

                    const col = std.mem.indexOfScalarPos(u8, line, 1, ':') orelse return error.BadRequest;
                    const name = line[0..col];
                    var value = line[col + 1 ..];
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

                    if (in_accum) {
                        line_buf.clearRetainingCapacity();
                        in_accum = false;
                    }
                    line_start = nl + 1;
                    search_pos = line_start;
                }

                if (done) {
                    break;
                }

                if (line_start < available.len) {
                    const rest = available[line_start..available.len];
                    total += rest.len;
                    if (total > max_header_bytes) return error.HeadersTooLarge;
                    if (!in_accum) {
                        if (!line_buf_inited) {
                            line_buf = .empty;
                            line_buf_inited = true;
                        } else {
                            line_buf.clearRetainingCapacity();
                        }
                        in_accum = true;
                    }
                    try line_buf.appendSlice(a, rest);
                }
                r.toss(available.len);
            }

            if (has_chunked and content_length != null) return error.BadRequest;
            if (has_chunked) {
                self._base.body_kind = .chunked;
            } else if (content_length) |cl| {
                self._base.body_kind = if (cl == 0) .none else .content_length;
                self._base.body_remaining = cl;
            } else {
                self._base.body_kind = .none;
            }

            if (HeaderLookup.count != 0) {
                try parse.doneParsingStruct(&self._headers, present[0..]);
            }
        }

        fn readExact(r: *Io.Reader, buf: []u8) Io.Reader.Error!void {
            try r.readSliceAll(buf);
        }

        fn bodyAllFrom(self: *Self, a: Allocator, r: *Io.Reader, max_bytes: usize) ![]const u8 {
            return switch (self._base.body_kind) {
                .none => "",
                .content_length => blk: {
                    const n = self._base.body_remaining;
                    if (n > max_bytes) return error.PayloadTooLarge;
                    const buf = try a.alloc(u8, n);
                    try readExact(r, buf);
                    self._base.body_remaining = 0;
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
                        if (size > max_bytes or start > max_bytes - size) return error.PayloadTooLarge;
                        try out.resize(a, start + size);
                        try readExact(r, out.items[start..][0..size]);
                        if (out.items.len > max_bytes) return error.PayloadTooLarge;
                        // chunk CRLF
                        var crlf: [2]u8 = undefined;
                        try readExact(r, crlf[0..]);
                        if (crlf[0] != '\r' or crlf[1] != '\n') return error.BadRequest;
                    }
                    self._base.body_kind = .none;
                    break :blk try out.toOwnedSlice(a);
                },
            };
        }

        /// Read and return the full request body, up to `max_bytes`.
        ///
        /// Requires headers to have been parsed for this request.
        pub fn bodyAll(self: *Self, max_bytes: usize) ![]const u8 {
            const r = self._base.reader orelse return error.BadRequest;
            return bodyAllFrom(self, self._base.arena, r, max_bytes);
        }

        fn discardUnreadBodyFrom(self: *Self, r: *Io.Reader) !void {
            switch (self._base.body_kind) {
                .none => return,
                .content_length => {
                    var remaining = self._base.body_remaining;
                    while (remaining != 0) {
                        const tossed = try r.discard(.limited(remaining));
                        remaining -= tossed;
                    }
                    self._base.body_remaining = 0;
                    self._base.body_kind = .none;
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
                    self._base.body_kind = .none;
                },
            }
        }

        /// Discard any unread request body bytes so the connection can be reused.
        ///
        /// Requires headers to have been parsed for this request.
        pub fn discardUnreadBody(self: *Self) !void {
            const r = self._base.reader orelse return error.BadRequest;
            return discardUnreadBodyFrom(self, r);
        }
    };
}

/// Implements request pwith pattern.
pub fn RequestPWithPattern(
    comptime Headers: type,
    comptime Query: type,
    comptime Params: type,
    comptime param_names: []const []const u8,
    comptime MwCtx: type,
    comptime route_pattern: []const u8,
    comptime method_name: []const u8,
) type {
    return RequestPWithPatternExt(Headers, Query, Params, param_names, MwCtx, struct {}, route_pattern, method_name, void);
}

/// Implements request pwith pattern static.
pub fn RequestPWithPatternStatic(
    comptime Headers: type,
    comptime Query: type,
    comptime Params: type,
    comptime param_names: []const []const u8,
    comptime MwCtx: type,
    comptime MwStaticCtx: type,
    comptime route_pattern: []const u8,
    comptime method_name: []const u8,
) type {
    return RequestPWithPatternExt(Headers, Query, Params, param_names, MwCtx, MwStaticCtx, route_pattern, method_name, void);
}

/// Implements request pwith pattern ctx.
pub fn RequestPWithPatternCtx(
    comptime Headers: type,
    comptime Query: type,
    comptime Params: type,
    comptime param_names: []const []const u8,
    comptime MwCtx: type,
    comptime route_pattern: []const u8,
    comptime method_name: []const u8,
    comptime CtxPtr: type,
) type {
    return RequestPWithPatternExt(Headers, Query, Params, param_names, MwCtx, struct {}, route_pattern, method_name, CtxPtr);
}

/// Implements request pwith pattern ctx static.
pub fn RequestPWithPatternCtxStatic(
    comptime Headers: type,
    comptime Query: type,
    comptime Params: type,
    comptime param_names: []const []const u8,
    comptime MwCtx: type,
    comptime MwStaticCtx: type,
    comptime route_pattern: []const u8,
    comptime method_name: []const u8,
    comptime CtxPtr: type,
) type {
    return RequestPWithPatternExt(Headers, Query, Params, param_names, MwCtx, MwStaticCtx, route_pattern, method_name, CtxPtr);
}

/// Implements request.
pub fn Request(comptime Headers: type, comptime Query: type, comptime param_names: []const []const u8, comptime MwCtx: type) type {
    return RequestPWithPattern(Headers, Query, struct {}, param_names, MwCtx, "", "GET");
}

/// Implements request with pattern.
pub fn RequestWithPattern(
    comptime Headers: type,
    comptime Query: type,
    comptime param_names: []const []const u8,
    comptime MwCtx: type,
    comptime route_pattern: []const u8,
) type {
    return RequestPWithPattern(Headers, Query, struct {}, param_names, MwCtx, route_pattern, "GET");
}

/// Implements request p.
pub fn RequestP(
    comptime Headers: type,
    comptime Query: type,
    comptime Params: type,
    comptime param_names: []const []const u8,
    comptime MwCtx: type,
) type {
    return RequestPWithPattern(Headers, Query, Params, param_names, MwCtx, "", "GET");
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
    defer gpa.free(body);
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

test "request line: owned duplicates path/query" {
    var r = Io.Reader.fixed("GET /hello HTTP/1.1\r\n");
    const gpa = std.testing.allocator;
    const line = try parseRequestLine(&r, gpa, 8 * 1024);
    defer gpa.free(line.method);
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
    try std.testing.expectEqual(BodyKind.chunked, reqv.baseConst().body_kind);
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
    try std.testing.expectEqual(BodyKind.chunked, reqv.baseConst().body_kind);
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
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello", body);
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
    defer gpa.free(body);
    try std.testing.expectEqualStrings("ok", body);
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
    defer gpa.free(body);
    try std.testing.expectEqualStrings("Wiki", body);
}

test "bodyAll/discardUnreadBody: require parseHeaders first" {
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
    try std.testing.expectError(error.BadRequest, reqv.bodyAll(1));
    try std.testing.expectError(error.BadRequest, reqv.discardUnreadBody());
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

test "fuzz: parseRequestLine owned alloc/free" {
    const corpus = &.{
        "GET / HTTP/1.1\r\n",
        "PUT /hello HTTP/1.1\r\n",
        "X / HTTP/1.1\r\n",
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
            const gpa = std.testing.allocator;
            if (parseRequestLine(&r, gpa, 8 * 1024)) |line| {
                defer gpa.free(line.method);
                defer gpa.free(line.path);
                defer gpa.free(line.query);
            } else |_| {}
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
