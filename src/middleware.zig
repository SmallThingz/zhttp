const std = @import("std");
const parse = @import("parse.zig");
const req_ctx = @import("req_ctx.zig");
const util = @import("util.zig");
const Res = @import("response.zig").Res;

comptime {
    @setEvalBranchQuota(50000);
}

pub const MiddlewareInfo = struct {
    /// Unique middleware name used for middleware data lookup.
    name: []const u8,
    /// Optional middleware data type stored in request middleware context.
    data: ?type = null,
    /// Optional path param capture type required by this middleware.
    path: ?type = null,
    /// Optional query capture type required by this middleware.
    query: ?type = null,
    /// Optional header capture type required by this middleware.
    header: ?type = null,
};

const EmptyTuple = std.meta.Tuple(&.{});

fn tupleConcatValuesType(comptime a: anytype, comptime b: anytype) type {
    const la: usize = comptime util.tupleLen(a);
    const lb: usize = comptime util.tupleLen(b);
    if (la == 0) return @TypeOf(b);
    if (lb == 0) return @TypeOf(a);
    const OutFieldTypes = comptime blk: {
        var out: [la + lb]type = undefined;
        for (@typeInfo(@TypeOf(a)).@"struct".fields, 0..) |f, i| {
            out[i] = @TypeOf(@field(a, f.name));
        }
        for (@typeInfo(@TypeOf(b)).@"struct".fields, 0..) |f, i| {
            out[la + i] = @TypeOf(@field(b, f.name));
        }
        break :blk out;
    };
    return std.meta.Tuple(&OutFieldTypes);
}

fn tupleConcatValues(comptime a: anytype, comptime b: anytype) tupleConcatValuesType(a, b) {
    const la: usize = comptime util.tupleLen(a);
    const lb: usize = comptime util.tupleLen(b);
    if (la == 0) return b;
    if (lb == 0) return a;

    const OutT = tupleConcatValuesType(a, b);
    return comptime blk: {
        var out: OutT = undefined;
        for (@typeInfo(@TypeOf(a)).@"struct".fields, 0..) |f, i| {
            @field(out, std.fmt.comptimePrint("{d}", .{i})) = @field(a, f.name);
        }
        for (@typeInfo(@TypeOf(b)).@"struct".fields, 0..) |f, i| {
            @field(out, std.fmt.comptimePrint("{d}", .{la + i})) = @field(b, f.name);
        }
        break :blk out;
    };
}

fn tupleTailType(comptime t: anytype) type {
    const fields = @typeInfo(@TypeOf(t)).@"struct".fields;
    if (fields.len <= 1) return EmptyTuple;
    const OutFieldTypes = comptime blk: {
        var out: [fields.len - 1]type = undefined;
        for (fields[1..], 0..) |f, i| {
            out[i] = @TypeOf(@field(t, f.name));
        }
        break :blk out;
    };
    return std.meta.Tuple(&OutFieldTypes);
}

fn tupleTail(comptime t: anytype) tupleTailType(t) {
    const fields = @typeInfo(@TypeOf(t)).@"struct".fields;
    if (fields.len <= 1) return .{};
    const OutT = tupleTailType(t);
    return comptime blk: {
        var out: OutT = undefined;
        for (fields[1..], 0..) |f, i| {
            @field(out, std.fmt.comptimePrint("{d}", .{i})) = @field(t, f.name);
        }
        break :blk out;
    };
}

/// Returns the combined type of middleware-provided routes.
pub fn routesType(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(50000);
    }
    const info0 = @typeInfo(@TypeOf(mws));
    if (info0 != .@"struct" or !info0.@"struct".is_tuple) @compileError("middlewares must be a tuple");
    const fields = info0.@"struct".fields;
    if (fields.len == 0) return EmptyTuple;

    const First = @field(mws, fields[0].name);
    const Rest = tupleTail(mws);

    const FirstRoutesT = comptime blk: {
        if (!@hasDecl(First, "Routes")) break :blk EmptyTuple;
        if (@hasDecl(First, "register_routes") and !First.register_routes) break :blk EmptyTuple;
        break :blk @TypeOf(First.Routes);
    };
    const RestRoutesT = routesType(Rest);
    const a: FirstRoutesT = undefined;
    const b: RestRoutesT = undefined;
    return tupleConcatValuesType(a, b);
}

/// Returns the combined middleware-provided route tuple.
pub fn routes(comptime mws: anytype) routesType(mws) {
    const info0 = @typeInfo(@TypeOf(mws));
    if (info0 != .@"struct" or !info0.@"struct".is_tuple) @compileError("middlewares must be a tuple");
    const fields = info0.@"struct".fields;
    if (fields.len == 0) return .{};

    const First = @field(mws, fields[0].name);
    const Rest = tupleTail(mws);

    const first_routes = comptime blk: {
        if (!@hasDecl(First, "Routes")) break :blk .{};
        if (@hasDecl(First, "register_routes") and !First.register_routes) break :blk .{};
        break :blk First.Routes;
    };
    const rest_routes = routes(Rest);
    return tupleConcatValues(first_routes, rest_routes);
}

/// Validates and returns middleware metadata.
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
pub fn needsHeaders(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(100000);
    }
    const fields = @typeInfo(@TypeOf(mws)).@"struct".fields;
    comptime var acc: type = struct {};
    inline for (fields) |f| {
        const Mw = @field(mws, f.name);
        const mw_info = info(Mw);
        if (mw_info.header) |Header| {
            acc = parse.mergeHeaderStructs(acc, Header);
        }
    }
    return acc;
}

/// Merges all middleware query capture requirements.
pub fn needsQuery(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(100000);
    }
    const fields = @typeInfo(@TypeOf(mws)).@"struct".fields;
    comptime var acc: type = struct {};
    inline for (fields) |f| {
        const Mw = @field(mws, f.name);
        const mw_info = info(Mw);
        if (mw_info.query) |Query| {
            acc = parse.mergeStructs(acc, Query);
        }
    }
    return acc;
}

/// Merges all middleware path capture requirements.
pub fn needsParams(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(100000);
    }
    const fields = @typeInfo(@TypeOf(mws)).@"struct".fields;
    comptime var acc: type = struct {};
    inline for (fields) |f| {
        const Mw = @field(mws, f.name);
        const mw_info = info(Mw);
        if (mw_info.path) |Path| {
            acc = parse.mergeStructs(acc, Path);
        }
    }
    return acc;
}

const EmptyMiddlewareData = struct {};

fn dataType(comptime Mw: type) type {
    const mw_info = info(Mw);
    if (mw_info.data) |Data| return Data;
    return EmptyMiddlewareData;
}

fn name(comptime Mw: type) []const u8 {
    return info(Mw).name;
}

fn hasStoredData(comptime Mw: type) bool {
    const Data = dataType(Mw);
    return Data != EmptyMiddlewareData and @sizeOf(Data) != 0;
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
pub fn contextType(comptime MwTuple: anytype) type {
    const fields = @typeInfo(@TypeOf(MwTuple)).@"struct".fields;
    comptime var field_count: usize = 0;
    inline for (fields) |f| {
        const Mw = @field(MwTuple, f.name);
        if (!hasStoredData(Mw)) continue;
        const mw_name = comptime name(Mw);
        const Data = dataType(Mw);

        comptime var seen = false;
        inline for (fields) |pf| {
            if (std.mem.eql(u8, pf.name, f.name)) break;
            const Prev = @field(MwTuple, pf.name);
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

    inline for (fields) |f| {
        const Mw = @field(MwTuple, f.name);
        if (!hasStoredData(Mw)) continue;
        const mw_name = comptime name(Mw);
        const Data = dataType(Mw);

        comptime var seen = false;
        inline for (fields) |pf| {
            if (std.mem.eql(u8, pf.name, f.name)) break;
            const Prev = @field(MwTuple, pf.name);
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
pub fn initContext(comptime MwTuple: anytype, comptime Ctx: type) Ctx {
    var ctx: Ctx = std.mem.zeroes(Ctx);
    const fields = @typeInfo(@TypeOf(MwTuple)).@"struct".fields;
    inline for (fields) |f| {
        const Mw = @field(MwTuple, f.name);
        if (comptime !hasStoredData(Mw)) continue;
        const mw_name = comptime name(Mw);

        comptime var seen = false;
        inline for (fields) |pf| {
            if (std.mem.eql(u8, pf.name, f.name)) break;
            const Prev = @field(MwTuple, pf.name);
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

/// Returns middleware context schema entries used by `ReqCtx`.
pub fn contextST(comptime MwTuple: anytype) []const req_ctx.ST {
    const fields = @typeInfo(@TypeOf(MwTuple)).@"struct".fields;
    comptime var count: usize = 0;
    inline for (fields) |f| {
        const Mw = @field(MwTuple, f.name);
        const mw_info = info(Mw);
        if (mw_info.data == null) continue;
        const Data = mw_info.data.?;
        if (@sizeOf(Data) == 0) continue;
        comptime var seen = false;
        inline for (fields) |pf| {
            if (comptime std.mem.eql(u8, pf.name, f.name)) break;
            const Prev = @field(MwTuple, pf.name);
            const prev_info = info(Prev);
            if (prev_info.data == null) continue;
            if (comptime std.mem.eql(u8, prev_info.name, mw_info.name)) {
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
        for (fields) |f| {
            const Mw = @field(MwTuple, f.name);
            const mw_info = info(Mw);
            if (mw_info.data == null) continue;
            const Data = mw_info.data.?;
            if (@sizeOf(Data) == 0) continue;
            var seen = false;
            for (fields) |pf| {
                if (std.mem.eql(u8, pf.name, f.name)) break;
                const Prev = @field(MwTuple, pf.name);
                const prev_info = info(Prev);
                if (prev_info.data == null) continue;
                if (std.mem.eql(u8, prev_info.name, mw_info.name)) {
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
pub fn typeList(comptime t: anytype) []const type {
    const fields = @typeInfo(@TypeOf(t)).@"struct".fields;
    if (fields.len == 0) return &.{};
    const out: [fields.len]type = comptime blk: {
        var tmp: [fields.len]type = undefined;
        for (fields, 0..) |f, i| tmp[i] = @field(t, f.name);
        break :blk tmp;
    };
    return out[0..];
}

pub const Static = @import("middleware/static.zig").Static;
pub const StaticOptions = @import("middleware/static.zig").StaticOptions;
pub const HeaderSetBehavior = @import("middleware/util.zig").HeaderSetBehavior;
pub const Cors = @import("middleware/cors.zig").Cors;
pub const CorsOptions = @import("middleware/cors.zig").CorsOptions;
pub const Logger = @import("middleware/logger.zig").Logger;
pub const LoggerOptions = @import("middleware/logger.zig").LoggerOptions;
pub const Compression = @import("middleware/compression.zig").Compression;
pub const CompressionOptions = @import("middleware/compression.zig").CompressionOptions;
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

test {
    _ = @import("middleware/mod.zig");
    _ = @import("middleware/static.zig");
    _ = @import("middleware/cors.zig");
    _ = @import("middleware/logger.zig");
    _ = @import("middleware/compression.zig");
    _ = @import("middleware/origin.zig");
    _ = @import("middleware/timeout.zig");
    _ = @import("middleware/etag.zig");
    _ = @import("middleware/request_id.zig");
    _ = @import("middleware/security_headers.zig");
}

test "middleware routes: register_routes=false is skipped" {
    const MwA = struct {
        pub const Info: MiddlewareInfo = .{ .name = "a" };
        pub const Routes = .{ "a-1", "a-2" };
        pub fn call(comptime rctx: req_ctx.ReqCtx, req: rctx.T()) !Res {
            _ = rctx;
            _ = req;
            return Res.text(200, "ok");
        }
    };
    const MwB = struct {
        pub const Info: MiddlewareInfo = .{ .name = "b" };
        pub const register_routes = false;
        pub const Routes = .{"b-1"};
        pub fn call(comptime rctx: req_ctx.ReqCtx, req: rctx.T()) !Res {
            _ = rctx;
            _ = req;
            return Res.text(200, "ok");
        }
    };
    const MwC = struct {
        pub const Info: MiddlewareInfo = .{ .name = "c" };
        pub fn call(comptime rctx: req_ctx.ReqCtx, req: rctx.T()) !Res {
            _ = rctx;
            _ = req;
            return Res.text(200, "ok");
        }
    };

    const out = routes(.{ MwA, MwB, MwC });
    try std.testing.expectEqual(@as(usize, 2), util.tupleLen(out));
    try std.testing.expectEqualStrings("a-1", @field(out, "0"));
    try std.testing.expectEqualStrings("a-2", @field(out, "1"));
}

test "middleware context: deduplicates by name and honors initData" {
    const AuthData = struct { value: u8 = 0 };
    const MwA = struct {
        pub const Info: MiddlewareInfo = .{ .name = "auth", .data = AuthData };
        pub fn initData() AuthData {
            return .{ .value = 7 };
        }
        pub fn call(comptime rctx: req_ctx.ReqCtx, req: rctx.T()) !Res {
            _ = rctx;
            _ = req;
            return Res.text(200, "ok");
        }
    };
    const MwB = struct {
        pub const Info: MiddlewareInfo = .{ .name = "auth", .data = AuthData };
        pub fn call(comptime rctx: req_ctx.ReqCtx, req: rctx.T()) !Res {
            _ = rctx;
            _ = req;
            return Res.text(200, "ok");
        }
    };
    const MwC = struct {
        pub const Info: MiddlewareInfo = .{ .name = "noop", .data = struct {} };
        pub fn call(comptime rctx: req_ctx.ReqCtx, req: rctx.T()) !Res {
            _ = rctx;
            _ = req;
            return Res.text(200, "ok");
        }
    };

    const mws = .{ MwA, MwB, MwC };
    const Ctx = contextType(mws);
    try std.testing.expect(@hasField(Ctx, "auth"));
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(Ctx).@"struct".fields.len);

    const ctx = initContext(mws, Ctx);
    try std.testing.expectEqual(@as(u8, 7), ctx.auth.value);

    const st = contextST(mws);
    try std.testing.expectEqual(@as(usize, 1), st.len);
    try std.testing.expectEqualStrings("auth", st[0].name);
    try std.testing.expect(st[0].T == AuthData);
}

test "middleware needs: merges header/query/path requirements" {
    const MwA = struct {
        pub const Info: MiddlewareInfo = .{
            .name = "a",
            .path = struct { id: parse.Int(u64) },
            .query = struct { page: parse.Optional(parse.Int(u32)) },
            .header = struct { x_token: parse.Optional(parse.String) },
        };
        pub fn call(comptime rctx: req_ctx.ReqCtx, req: rctx.T()) !Res {
            _ = rctx;
            _ = req;
            return Res.text(200, "ok");
        }
    };
    const MwB = struct {
        pub const Info: MiddlewareInfo = .{
            .name = "b",
            .path = struct { slug: parse.Optional(parse.String) },
            .query = struct {
                page: parse.Optional(parse.Int(u32)),
                q: parse.Optional(parse.String),
            },
            .header = struct {
                X_TOKEN: parse.Optional(parse.String),
                host: parse.Optional(parse.String),
            },
        };
        pub fn call(comptime rctx: req_ctx.ReqCtx, req: rctx.T()) !Res {
            _ = rctx;
            _ = req;
            return Res.text(200, "ok");
        }
    };

    const Headers = needsHeaders(.{ MwA, MwB });
    try std.testing.expect(@hasField(Headers, "host"));
    try std.testing.expect(@hasField(Headers, "x_token") or @hasField(Headers, "X_TOKEN"));
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(Headers).@"struct".fields.len);

    const Query = needsQuery(.{ MwA, MwB });
    try std.testing.expect(@hasField(Query, "page"));
    try std.testing.expect(@hasField(Query, "q"));
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(Query).@"struct".fields.len);

    const Params = needsParams(.{ MwA, MwB });
    try std.testing.expect(@hasField(Params, "id"));
    try std.testing.expect(@hasField(Params, "slug"));
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(Params).@"struct".fields.len);
}

test "middleware typeList: preserves tuple order" {
    const out = typeList(.{ u8, u16, bool });
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expect(out[0] == u8);
    try std.testing.expect(out[1] == u16);
    try std.testing.expect(out[2] == bool);
}
