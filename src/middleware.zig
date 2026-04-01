const std = @import("std");
const parse = @import("parse.zig");
const req_ctx = @import("req_ctx.zig");
const route_decl = @import("route_decl.zig");

comptime {
    @setEvalBranchQuota(200_000);
}

pub const MiddlewareInfo = struct {
    /// Unique middleware name used for middleware data lookup.
    name: []const u8,
    /// Optional middleware data type stored in request middleware context.
    data: ?type = null,
    /// Optional per-route static context type for this middleware.
    ///
    /// If set, initialization runs once at server startup per route.
    /// When this type exposes
    /// `pub fn init(io: std.Io, allocator: std.mem.Allocator, route_decl: zhttp.router.RouteDecl) Self|!Self`,
    /// that function is used to build the route-local context value and any init error
    /// is returned from `Server.init`.
    ///
    /// Optional teardown hook:
    /// `pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void|!void`.
    /// When present, `Server.deinit` invokes it once per initialized route context.
    static_context: ?type = null,
    /// Optional path param capture type required by this middleware.
    path: ?type = null,
    /// Optional query capture type required by this middleware.
    query: ?type = null,
    /// Optional header capture type required by this middleware.
    header: ?type = null,
};

pub const StaticContextRouteDecl = route_decl.RouteDecl;

/// Validates and returns middleware metadata.
///
/// Expected middleware type shape:
/// - `pub const Info: zhttp.middleware.MiddlewareInfo`
/// - `pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !Res`
pub fn info(comptime Mw: type) MiddlewareInfo {
    if (!@hasDecl(Mw, "Info")) {
        @compileError("middleware " ++ @typeName(Mw) ++ " must expose `pub const Info: zhttp.middleware.MiddlewareInfo`");
    }
    if (!@hasDecl(Mw, "call")) {
        @compileError("middleware " ++ @typeName(Mw) ++ " must expose `pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res`");
    }
    const out = Mw.Info;

    if (@TypeOf(out) != MiddlewareInfo) {
        @compileError("middleware " ++ @typeName(Mw) ++ " has invalid Info type; expected zhttp.middleware.MiddlewareInfo");
    }
    if (@TypeOf(out.name) != []const u8) {
        @compileError("middleware " ++ @typeName(Mw) ++ " Info.name must be []const u8");
    }
    if (out.name.len == 0) {
        @compileError("middleware " ++ @typeName(Mw) ++ " Info.name must not be empty");
    }
    if (out.path) |Path| {
        if (@typeInfo(Path) != .@"struct") {
            @compileError("middleware " ++ @typeName(Mw) ++ " Info.path must be a struct type");
        }
    }
    if (out.static_context) |StaticContext| {
        if (@typeInfo(StaticContext) != .@"struct") {
            @compileError("middleware " ++ @typeName(Mw) ++ " Info.static_context must be a struct type");
        }
    }
    if (out.query) |Query| {
        if (@typeInfo(Query) != .@"struct") {
            @compileError("middleware " ++ @typeName(Mw) ++ " Info.query must be a struct type");
        }
    }
    if (out.header) |Header| {
        if (@typeInfo(Header) != .@"struct") {
            @compileError("middleware " ++ @typeName(Mw) ++ " Info.header must be a struct type");
        }
    }
    return out;
}

/// Merges all middleware header capture requirements.
///
/// Expected input shape:
/// - `mws` is accepted by `typeList` (tuple / `[]const type` / `[N]type` / `*const [N]type`)
/// - every middleware type in `mws` satisfies `info(...)` shape checks
pub fn needsHeaders(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(200_000);
    }
    const list = typeList(mws);
    comptime var acc: type = struct {};
    inline for (list) |Mw| {
        const mw_info = info(Mw);
        if (mw_info.header) |Header| {
            acc = parse.mergeHeaderStructs(acc, Header);
        }
    }
    return acc;
}

/// Merges all middleware query capture requirements.
///
/// Expected input shape:
/// - same as `needsHeaders`.
pub fn needsQuery(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(200_000);
    }
    const list = typeList(mws);
    comptime var acc: type = struct {};
    inline for (list) |Mw| {
        const mw_info = info(Mw);
        if (mw_info.query) |Query| {
            acc = parse.mergeStructs(acc, Query);
        }
    }
    return acc;
}

/// Merges all middleware path capture requirements.
///
/// Expected input shape:
/// - same as `needsHeaders`.
pub fn needsParams(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(200_000);
    }
    const list = typeList(mws);
    comptime var acc: type = struct {};
    inline for (list) |Mw| {
        const mw_info = info(Mw);
        if (mw_info.path) |Path| {
            acc = parse.mergeStructs(acc, Path);
        }
    }
    return acc;
}

const EmptyMiddlewareData = struct {};
const EmptyMiddlewareStaticContext = struct {};

fn dataType(comptime Mw: type) type {
    const mw_info = info(Mw);
    if (mw_info.data) |Data| return Data;
    return EmptyMiddlewareData;
}

fn staticContextTypeForMw(comptime Mw: type) type {
    const mw_info = info(Mw);
    if (mw_info.static_context) |StaticContext| return StaticContext;
    return EmptyMiddlewareStaticContext;
}

fn name(comptime Mw: type) []const u8 {
    return info(Mw).name;
}

fn hasStoredData(comptime Mw: type) bool {
    const Data = dataType(Mw);
    return Data != EmptyMiddlewareData and @sizeOf(Data) != 0;
}

fn hasStoredStaticContext(comptime Mw: type) bool {
    const StaticContext = staticContextTypeForMw(Mw);
    if (StaticContext == EmptyMiddlewareStaticContext) return false;
    return @sizeOf(StaticContext) != 0 or @hasDecl(StaticContext, "init");
}

fn initData(comptime Mw: type) dataType(Mw) {
    const Data = dataType(Mw);
    if (Data == EmptyMiddlewareData) return .{};
    if (@hasDecl(Mw, "initData")) {
        return @call(.always_inline, Mw.initData, .{});
    }
    return std.mem.zeroes(Data);
}

/// Builds the middleware context struct type used by requests.
///
/// Expected input shape:
/// - `mws` is accepted by `typeList`.
/// - each middleware with `Info.data` uses a struct-compatible type.
pub fn contextType(comptime mws: anytype) type {
    const list = typeList(mws);
    comptime var field_count: usize = 0;
    inline for (list, 0..) |Mw, i| {
        if (!hasStoredData(Mw)) continue;
        const mw_name = comptime name(Mw);
        const Data = dataType(Mw);

        comptime var seen = false;
        inline for (list[0..i]) |Prev| {
            if (!hasStoredData(Prev)) continue;
            const prev_name = comptime name(Prev);
            if (comptime std.mem.eql(u8, prev_name, mw_name)) {
                const PrevData = dataType(Prev);
                if (PrevData != Data) {
                    @compileError("middleware data field '" ++ mw_name ++ "' has conflicting Data types");
                }
                seen = true;
                break;
            }
        }
        if (!seen) field_count += 1;
    }

    if (field_count == 0) return struct {};

    comptime var out_names: [field_count][]const u8 = undefined;
    comptime var out_types: [field_count]type = undefined;
    comptime var out_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    comptime var out_index: usize = 0;

    inline for (list, 0..) |Mw, i| {
        if (!hasStoredData(Mw)) continue;
        const mw_name = comptime name(Mw);
        const Data = dataType(Mw);

        comptime var seen = false;
        inline for (list[0..i]) |Prev| {
            if (!hasStoredData(Prev)) continue;
            const prev_name = comptime name(Prev);
            if (comptime std.mem.eql(u8, prev_name, mw_name)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        out_names[out_index] = mw_name;
        out_types[out_index] = Data;
        out_attrs[out_index] = .{
            .@"comptime" = false,
            .@"align" = @alignOf(Data),
            .default_value_ptr = null,
        };
        out_index += 1;
    }

    return @Struct(.auto, null, out_names[0..], &out_types, &out_attrs);
}

/// Initializes middleware context values for one request.
///
/// Expected input shape:
/// - `mws` is accepted by `typeList`.
/// - `Ctx` is exactly the type returned by `contextType(mws)`.
pub fn initContext(comptime mws: anytype, comptime Ctx: type) Ctx {
    const list = typeList(mws);
    var ctx: Ctx = std.mem.zeroes(Ctx);
    inline for (list, 0..) |Mw, i| {
        if (comptime !hasStoredData(Mw)) continue;
        const mw_name = comptime name(Mw);

        comptime var seen = false;
        inline for (list[0..i]) |Prev| {
            if (comptime !hasStoredData(Prev)) continue;
            const prev_name = comptime name(Prev);
            if (comptime std.mem.eql(u8, prev_name, mw_name)) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            @field(ctx, mw_name) = initData(Mw);
        }
    }
    return ctx;
}

/// Builds the per-route static middleware context struct type.
///
/// Expected input shape:
/// - `mws` is accepted by `typeList`.
/// - each middleware optional `Info.static_context` is a struct type.
pub fn staticContextType(comptime mws: anytype) type {
    const list = typeList(mws);
    comptime var field_count: usize = 0;
    inline for (list, 0..) |Mw, i| {
        if (!hasStoredStaticContext(Mw)) continue;
        const mw_name = comptime name(Mw);
        const StaticContext = staticContextTypeForMw(Mw);

        comptime var seen = false;
        inline for (list[0..i]) |Prev| {
            if (!hasStoredStaticContext(Prev)) continue;
            const prev_name = comptime name(Prev);
            if (comptime std.mem.eql(u8, prev_name, mw_name)) {
                const PrevStaticContext = staticContextTypeForMw(Prev);
                if (PrevStaticContext != StaticContext) {
                    @compileError("middleware static_context field '" ++ mw_name ++ "' has conflicting types");
                }
                seen = true;
                break;
            }
        }
        if (!seen) field_count += 1;
    }

    if (field_count == 0) return struct {};

    comptime var out_names: [field_count][]const u8 = undefined;
    comptime var out_types: [field_count]type = undefined;
    comptime var out_attrs: [field_count]std.builtin.Type.StructField.Attributes = undefined;
    comptime var out_index: usize = 0;

    inline for (list, 0..) |Mw, i| {
        if (!hasStoredStaticContext(Mw)) continue;
        const mw_name = comptime name(Mw);
        const StaticContext = staticContextTypeForMw(Mw);

        comptime var seen = false;
        inline for (list[0..i]) |Prev| {
            if (!hasStoredStaticContext(Prev)) continue;
            const prev_name = comptime name(Prev);
            if (comptime std.mem.eql(u8, prev_name, mw_name)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        out_names[out_index] = mw_name;
        out_types[out_index] = StaticContext;
        out_attrs[out_index] = .{
            .@"comptime" = false,
            .@"align" = @alignOf(StaticContext),
            .default_value_ptr = null,
        };
        out_index += 1;
    }

    return @Struct(.auto, null, out_names[0..], &out_types, &out_attrs);
}

/// Initializes per-route static middleware context values.
///
/// Expected shape:
/// - `Ctx` is the type returned by `staticContextType(...)`.
/// - for each field type `S` in `Ctx`, optional hooks are:
///   `pub fn init(io: std.Io, allocator: std.mem.Allocator, route_decl: zhttp.route_decl.RouteDecl) S|!S`
///   `pub fn deinit(self: *S, io: std.Io, allocator: std.mem.Allocator) void|!void`
pub fn initStaticContext(
    comptime Ctx: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    rd: StaticContextRouteDecl,
) !Ctx {
    var ctx: Ctx = std.mem.zeroes(Ctx);
    const fields = std.meta.fields(Ctx);
    var initialized_count: usize = 0;
    errdefer {
        // Unwind in reverse order so teardown mirrors successful init.
        inline for (fields, 0..) |_, rev_i| {
            const i = fields.len - 1 - rev_i;
            if (i < initialized_count) {
                const f = fields[i];
                if (@hasDecl(f.type, "deinit")) {
                    const deinit_fn = f.type.deinit;
                    const ret = @call(.auto, deinit_fn, .{ &@field(ctx, f.name), io, allocator });
                    const RetT = @TypeOf(ret);
                    if (RetT == void) {
                        // nothing to do
                    } else if (@typeInfo(RetT) == .error_union and @typeInfo(RetT).error_union.payload == void) {
                        ret catch {};
                    } else {
                        @compileError("middleware static context deinit must return void or !void");
                    }
                }
            }
        }
    }
    inline for (fields, 0..) |f, i| {
        if (@hasDecl(f.type, "init")) {
            const init_fn = f.type.init;
            const ret = @call(.auto, init_fn, .{ io, allocator, rd });
            const RetT = @TypeOf(ret);
            if (RetT == f.type) {
                @field(ctx, f.name) = ret;
            } else if (@typeInfo(RetT) == .error_union and @typeInfo(RetT).error_union.payload == f.type) {
                @field(ctx, f.name) = try ret;
            } else {
                @compileError("middleware static context init must return StaticContext or !StaticContext");
            }
        } else {
            @field(ctx, f.name) = std.mem.zeroes(f.type);
        }
        initialized_count = i + 1;
    }
    return ctx;
}

/// Tears down per-route static middleware context values.
///
/// Expected shape:
/// - `Ctx` is the type returned by `staticContextType(...)`.
/// - each field type optional `deinit` hook matches:
///   `pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void|!void`
pub fn deinitStaticContext(
    comptime Ctx: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    ctx: *Ctx,
) void {
    const fields = std.meta.fields(Ctx);
    // Deinitialize in reverse order so dependencies mirror init traversal.
    inline for (fields, 0..) |_, rev_i| {
        const f = fields[fields.len - 1 - rev_i];
        if (!@hasDecl(f.type, "deinit")) continue;
        const deinit_fn = f.type.deinit;
        const ret = @call(.auto, deinit_fn, .{ &@field(ctx.*, f.name), io, allocator });
        const RetT = @TypeOf(ret);
        if (RetT == void) continue;
        if (@typeInfo(RetT) == .error_union and @typeInfo(RetT).error_union.payload == void) {
            ret catch {};
            continue;
        }
        @compileError("middleware static context deinit must return void or !void");
    }
}

/// Returns middleware context schema entries used by `ReqCtx`.
///
/// Expected input shape:
/// - `mws` is accepted by `typeList`.
/// - every middleware satisfies `info(...)` checks.
pub fn contextST(comptime mws: anytype) []const req_ctx.ST {
    const list = typeList(mws);
    comptime var count: usize = 0;
    inline for (list, 0..) |Mw, i| {
        const mw_info = info(Mw);
        if (mw_info.data == null) continue;
        const Data = mw_info.data.?;
        if (@sizeOf(Data) == 0) continue;
        comptime var seen = false;
        inline for (list[0..i]) |Prev| {
            const prev_info = info(Prev);
            if (prev_info.data == null) continue;
            if (comptime std.mem.eql(u8, prev_info.name, mw_info.name)) {
                if (prev_info.data.? != Data) {
                    @compileError("middleware data field '" ++ mw_info.name ++ "' has conflicting Data types");
                }
                seen = true;
                break;
            }
        }
        if (!seen) count += 1;
    }
    if (count == 0) return &.{};

    const out: [count]req_ctx.ST = comptime blk: {
        var tmp: [count]req_ctx.ST = undefined;
        var i: usize = 0;
        for (list, 0..) |Mw, idx| {
            const mw_info = info(Mw);
            if (mw_info.data == null) continue;
            const Data = mw_info.data.?;
            if (@sizeOf(Data) == 0) continue;
            var seen = false;
            for (list[0..idx]) |Prev| {
                const prev_info = info(Prev);
                if (prev_info.data == null) continue;
                if (std.mem.eql(u8, prev_info.name, mw_info.name)) {
                    if (prev_info.data.? != Data) {
                        @compileError("middleware data field '" ++ mw_info.name ++ "' has conflicting Data types");
                    }
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            tmp[i] = .{ .name = mw_info.name, .T = Data };
            i += 1;
        }
        break :blk tmp;
    };
    return out[0..];
}

/// Returns middleware tuple elements as a flat `[]const type`.
///
/// Accepted `mws` shapes:
/// - tuple of middleware types (`.{ MwA, MwB }`)
/// - `[]const type`
/// - `[N]type`
/// - `*const [N]type`
pub fn typeList(comptime mws: anytype) []const type {
    const T = @TypeOf(mws);
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            if (!s.is_tuple) @compileError("middlewares must be a tuple, []const type, [N]type, or *const [N]type");
            if (s.fields.len == 0) break :blk &.{};
            const out: [s.fields.len]type = comptime blk2: {
                var tmp: [s.fields.len]type = undefined;
                for (s.fields, 0..) |f, i| tmp[i] = @field(mws, f.name);
                break :blk2 tmp;
            };
            break :blk out[0..];
        },
        .array => |a| blk: {
            if (a.child != type) @compileError("middleware array must be [N]type");
            break :blk mws[0..];
        },
        .pointer => |p| blk: {
            if (p.size == .slice) {
                if (p.child != type) @compileError("middleware slice must be []const type");
                break :blk mws;
            }
            if (p.size == .one) {
                const child_info = @typeInfo(p.child);
                if (child_info == .array and child_info.array.child == type) {
                    break :blk mws[0..];
                }
            }
            @compileError("middlewares must be a tuple, []const type, [N]type, or *const [N]type");
        },
        else => @compileError("middlewares must be a tuple, []const type, [N]type, or *const [N]type"),
    };
}

/// Concatenates two middleware type lists.
pub fn concatTypeLists(comptime a: []const type, comptime b: []const type) []const type {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    const out: [a.len + b.len]type = comptime blk: {
        var tmp: [a.len + b.len]type = undefined;
        for (a, 0..) |Mw, i| tmp[i] = Mw;
        for (b, 0..) |Mw, i| tmp[a.len + i] = Mw;
        break :blk tmp;
    };
    return out[0..];
}

pub const Static = @import("middleware/static.zig").Static;
pub const StaticOptions = @import("middleware/static.zig").StaticOptions;
pub const HeaderSetBehavior = @import("middleware/util.zig").HeaderSetBehavior;
pub const Cors = @import("middleware/cors.zig").Cors;
pub const CorsOptions = @import("middleware/cors.zig").CorsOptions;
pub const CorsSignature = @import("middleware/cors.zig").CorsSignature;
pub const Logger = @import("middleware/logger.zig").Logger;
pub const LoggerOptions = @import("middleware/logger.zig").LoggerOptions;
pub const Compression = @import("middleware/compression.zig").Compression;
pub const CompressionScheme = @import("middleware/compression.zig").CompressionScheme;
pub const CompressionOptions = @import("middleware/compression.zig").CompressionOptions;
pub const Expect = @import("middleware/expect.zig").Expect;
pub const ExpectOptions = @import("middleware/expect.zig").ExpectOptions;
pub const Origin = @import("middleware/origin.zig").Origin;
pub const OriginOptions = @import("middleware/origin.zig").OriginOptions;
pub const OriginDecisionTree = @import("middleware/origin.zig").DecisionTree;
pub const OriginHashMatcher = @import("middleware/origin.zig").HashMatcher;
pub const Timeout = @import("middleware/timeout.zig").Timeout;
pub const TimeoutOptions = @import("middleware/timeout.zig").TimeoutOptions;
pub const Etag = @import("middleware/etag.zig").Etag;
pub const EtagOptions = @import("middleware/etag.zig").EtagOptions;
pub const RequestId = @import("middleware/request_id.zig").RequestId;
pub const RequestIdOptions = @import("middleware/request_id.zig").RequestIdOptions;
pub const SecurityHeaders = @import("middleware/security_headers.zig").SecurityHeaders;
pub const SecurityHeadersOptions = @import("middleware/security_headers.zig").SecurityHeadersOptions;
pub const staticContentTypeFor = @import("middleware/static.zig").contentTypeFor;

test "middleware helpers: merge needs, dedupe context data, and init static context" {
    const testing = std.testing;
    const AuthData = struct { counter: u8 };

    const StaticCtx = struct {
        pattern: []const u8,

        pub fn init(_: std.Io, _: std.mem.Allocator, rd: StaticContextRouteDecl) @This() {
            return .{ .pattern = rd.pattern };
        }

        pub fn deinit(self: *@This(), _: std.Io, _: std.mem.Allocator) void {
            self.pattern = "";
        }
    };

    const MwA = struct {
        pub const Info: MiddlewareInfo = .{
            .name = "auth",
            .data = AuthData,
            .static_context = StaticCtx,
            .header = struct { x_token: parse.Optional(parse.String) },
            .query = struct { page: parse.Optional(parse.Int(u8)) },
            .path = struct { id: parse.Int(u32) },
        };

        pub fn call(_: anytype, _: anytype) !@import("response.zig").Res {
            unreachable;
        }

        pub fn initData() Info.data.? {
            return .{ .counter = 7 };
        }
    };

    const MwADupe = struct {
        pub const Info: MiddlewareInfo = .{
            .name = "auth",
            .data = AuthData,
            .static_context = StaticCtx,
            .header = struct { host: parse.Optional(parse.String) },
            .query = struct { q: parse.Optional(parse.String) },
            .path = struct { slug: parse.String },
        };

        pub fn call(_: anytype, _: anytype) !@import("response.zig").Res {
            unreachable;
        }
    };

    const MwB = struct {
        pub const Info: MiddlewareInfo = .{
            .name = "trace",
            .data = struct { enabled: bool },
        };

        pub fn call(_: anytype, _: anytype) !@import("response.zig").Res {
            unreachable;
        }
    };

    const headers_t = needsHeaders(.{ MwA, MwADupe });
    try testing.expect(@hasField(headers_t, "x_token"));
    try testing.expect(@hasField(headers_t, "host"));

    const query_t = needsQuery(.{ MwA, MwADupe });
    try testing.expect(@hasField(query_t, "page"));
    try testing.expect(@hasField(query_t, "q"));

    const params_t = needsParams(.{ MwA, MwADupe });
    try testing.expect(@hasField(params_t, "id"));
    try testing.expect(@hasField(params_t, "slug"));

    const Ctx = contextType(.{ MwA, MwADupe, MwB });
    try testing.expect(@hasField(Ctx, "auth"));
    try testing.expect(@hasField(Ctx, "trace"));
    try testing.expectEqual(@as(usize, 2), std.meta.fields(Ctx).len);

    const ctx = comptime initContext(.{ MwA, MwADupe, MwB }, Ctx);
    try testing.expectEqual(@as(u8, 7), ctx.auth.counter);
    try testing.expectEqual(false, ctx.trace.enabled);

    const st = comptime contextST(.{ MwA, MwADupe, MwB });
    try testing.expectEqual(@as(usize, 2), st.len);
    try testing.expectEqualStrings("auth", st[0].name);
    try testing.expectEqualStrings("trace", st[1].name);

    const StaticCtxT = staticContextType(.{ MwA, MwADupe, MwB });
    try testing.expect(@hasField(StaticCtxT, "auth"));
    try testing.expectEqual(@as(usize, 1), std.meta.fields(StaticCtxT).len);

    const rd: StaticContextRouteDecl = .{
        .method = "GET",
        .pattern = "/items/{id}",
        .endpoint = struct {},
        .headers = struct {},
        .query = struct {},
        .params = struct {},
        .middlewares = &.{},
        .operations = &.{},
    };
    var static_ctx = try initStaticContext(StaticCtxT, testing.io, testing.allocator, rd);
    try testing.expectEqualStrings("/items/{id}", static_ctx.auth.pattern);
    deinitStaticContext(StaticCtxT, testing.io, testing.allocator, &static_ctx);
    try testing.expectEqualStrings("", static_ctx.auth.pattern);
}

test "middleware helpers: typeList and concatTypeLists support tuple/array inputs" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    const tuple_list = comptime typeList(.{ A, B });
    try std.testing.expectEqual(@as(usize, 2), tuple_list.len);
    comptime {
        if (tuple_list[0] != A or tuple_list[1] != B) @compileError("tuple typeList order changed");
    }

    const array = comptime [_]type{B};
    const array_list = comptime typeList(array);
    try std.testing.expectEqual(@as(usize, 1), array_list.len);
    comptime {
        if (array_list[0] != B) @compileError("array typeList order changed");
    }

    const joined = comptime concatTypeLists(tuple_list, &.{C});
    try std.testing.expectEqual(@as(usize, 3), joined.len);
    comptime {
        if (joined[2] != C) @compileError("concatTypeLists order changed");
    }
}

test "middleware helpers: deinitStaticContext accepts !void deinit hooks" {
    const FallibleCtx = struct {
        called: *bool,

        pub fn deinit(self: *@This(), _: std.Io, _: std.mem.Allocator) !void {
            self.called.* = true;
            return error.DeinitFailed;
        }
    };

    const InfallibleCtx = struct {
        called: *bool,

        pub fn deinit(self: *@This(), _: std.Io, _: std.mem.Allocator) void {
            self.called.* = true;
        }
    };

    const Ctx = struct {
        fallible: FallibleCtx,
        infallible: InfallibleCtx,
    };

    var fallible_called = false;
    var infallible_called = false;
    var ctx: Ctx = .{
        .fallible = .{ .called = &fallible_called },
        .infallible = .{ .called = &infallible_called },
    };

    deinitStaticContext(Ctx, std.testing.io, std.testing.allocator, &ctx);
    try std.testing.expect(fallible_called);
    try std.testing.expect(infallible_called);
}

test "middleware helpers: deinitStaticContext runs in reverse field order" {
    const DeinitA = struct {
        order: *[2]u8,
        idx: *usize,

        pub fn deinit(self: *@This(), _: std.Io, _: std.mem.Allocator) void {
            self.order.*[self.idx.*] = 'A';
            self.idx.* += 1;
        }
    };
    const DeinitB = struct {
        order: *[2]u8,
        idx: *usize,

        pub fn deinit(self: *@This(), _: std.Io, _: std.mem.Allocator) void {
            self.order.*[self.idx.*] = 'B';
            self.idx.* += 1;
        }
    };
    const Ctx = struct {
        a: DeinitA,
        b: DeinitB,
    };

    var order: [2]u8 = undefined;
    var idx: usize = 0;
    var ctx: Ctx = .{
        .a = .{ .order = &order, .idx = &idx },
        .b = .{ .order = &order, .idx = &idx },
    };
    deinitStaticContext(Ctx, std.testing.io, std.testing.allocator, &ctx);
    try std.testing.expectEqual(@as(usize, 2), idx);
    try std.testing.expectEqual('B', order[0]);
    try std.testing.expectEqual('A', order[1]);
}

test "middleware helpers: initStaticContext unwinds initialized fields on failure" {
    const AllocCtx = struct {
        buf: []u8 = &.{},

        pub fn init(_: std.Io, allocator: std.mem.Allocator, _: StaticContextRouteDecl) !@This() {
            return .{ .buf = try allocator.alloc(u8, 64) };
        }

        pub fn deinit(self: *@This(), _: std.Io, allocator: std.mem.Allocator) void {
            if (self.buf.len != 0) allocator.free(self.buf);
            self.buf = &.{};
        }
    };
    const FailCtx = struct {
        pub fn init(_: std.Io, _: std.mem.Allocator, _: StaticContextRouteDecl) !@This() {
            return error.ExpectedInitFailure;
        }
    };
    const Ctx = struct {
        alloc: AllocCtx,
        fail: FailCtx,
    };
    const rd: StaticContextRouteDecl = .{
        .method = "GET",
        .pattern = "/x",
        .endpoint = struct {},
        .headers = struct {},
        .query = struct {},
        .params = struct {},
        .middlewares = &.{},
        .operations = &.{},
    };

    try std.testing.expectError(
        error.ExpectedInitFailure,
        initStaticContext(Ctx, std.testing.io, std.testing.allocator, rd),
    );
}

test "middleware helpers: info returns declared metadata and init handles error-union static context" {
    const testing = std.testing;

    const StaticCtx = struct {
        method: []const u8,

        pub fn init(_: std.Io, _: std.mem.Allocator, rd: StaticContextRouteDecl) !@This() {
            return .{ .method = rd.method };
        }
    };

    const Mw = struct {
        pub const Info: MiddlewareInfo = .{
            .name = "demo",
            .data = struct { seen: bool = false },
            .static_context = StaticCtx,
            .header = struct { host: parse.Optional(parse.String) },
            .query = struct { q: parse.Optional(parse.String) },
            .path = struct { id: parse.Int(u32) },
        };

        pub fn call(_: anytype, _: anytype) !@import("response.zig").Res {
            unreachable;
        }
    };

    const mw_info = comptime info(Mw);
    try testing.expectEqualStrings("demo", mw_info.name);
    try testing.expect(mw_info.data.? == Mw.Info.data.?);
    try testing.expect(mw_info.static_context.? == StaticCtx);
    try testing.expect(mw_info.header.? == Mw.Info.header.?);
    try testing.expect(mw_info.query.? == Mw.Info.query.?);
    try testing.expect(mw_info.path.? == Mw.Info.path.?);

    const StaticCtxT = staticContextType(.{Mw});
    const rd: StaticContextRouteDecl = .{
        .method = "POST",
        .pattern = "/items/{id}",
        .endpoint = struct {},
        .headers = struct {},
        .query = struct {},
        .params = struct {},
        .middlewares = &.{},
        .operations = &.{},
    };
    const static_ctx = try initStaticContext(StaticCtxT, testing.io, testing.allocator, rd);
    try testing.expectEqualStrings("POST", static_ctx.demo.method);
}

test "middleware helpers: zero-sized data is omitted from stored middleware context" {
    const MwStored = struct {
        pub const Info: MiddlewareInfo = .{
            .name = "stored",
            .data = struct { count: u8 },
        };

        pub fn call(_: anytype, _: anytype) !@import("response.zig").Res {
            unreachable;
        }
    };

    const MwEmpty = struct {
        pub const Info: MiddlewareInfo = .{
            .name = "empty",
            .data = struct {},
        };

        pub fn call(_: anytype, _: anytype) !@import("response.zig").Res {
            unreachable;
        }
    };

    const Ctx = contextType(.{ MwStored, MwEmpty });
    try std.testing.expect(@hasField(Ctx, "stored"));
    try std.testing.expect(!@hasField(Ctx, "empty"));

    const st = comptime contextST(.{ MwStored, MwEmpty });
    try std.testing.expectEqual(@as(usize, 1), st.len);
    try std.testing.expectEqualStrings("stored", st[0].name);
    try std.testing.expect(st[0].T == MwStored.Info.data.?);
}
