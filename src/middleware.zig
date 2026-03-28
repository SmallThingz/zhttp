const std = @import("std");
const parse = @import("parse.zig");
const req_ctx = @import("req_ctx.zig");
const util = @import("util.zig");

comptime {
    @setEvalBranchQuota(50000);
}

pub const MiddlewareInfo = struct {
    name: []const u8,
    data: ?type = null,
    path: ?type = null,
    query: ?type = null,
    header: ?type = null,
};

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
    if (fields.len <= 1) return @TypeOf(.{});
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

pub fn routesType(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(50000);
    }
    const info0 = @typeInfo(@TypeOf(mws));
    if (info0 != .@"struct" or !info0.@"struct".is_tuple) @compileError("middlewares must be a tuple");
    const fields = info0.@"struct".fields;
    if (fields.len == 0) return @TypeOf(.{});

    const First = @field(mws, fields[0].name);
    const Rest = tupleTail(mws);

    const FirstRoutesT = comptime blk: {
        if (!@hasDecl(First, "Routes")) break :blk @TypeOf(.{});
        if (@hasDecl(First, "register_routes") and !First.register_routes) break :blk @TypeOf(.{});
        break :blk @TypeOf(First.Routes);
    };
    const RestRoutesT = routesType(Rest);
    const a: FirstRoutesT = undefined;
    const b: RestRoutesT = undefined;
    return tupleConcatValuesType(a, b);
}

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

pub fn info(comptime Mw: type) MiddlewareInfo {
    if (!@hasDecl(Mw, "Info")) {
        @compileError("middleware " ++ @typeName(Mw) ++ " must expose `pub const Info: zhttp.middleware.MiddlewareInfo`");
    }
    if (!@hasDecl(Mw, "call")) {
        @compileError("middleware " ++ @typeName(Mw) ++ " must expose `pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res`");
    }
    if (!@hasDecl(Mw, "Override")) {
        @compileError("middleware " ++ @typeName(Mw) ++ " must expose `pub fn Override(comptime rctx: ReqCtx) type`");
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
            acc = parse.mergeStructs(acc, Header);
        }
    }
    return acc;
}

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
pub const Cors = @import("middleware/cors.zig").Cors;
pub const Logger = @import("middleware/logger.zig").Logger;
pub const Compression = @import("middleware/compression.zig").Compression;
pub const Origin = @import("middleware/origin.zig").Origin;
pub const OriginDecisionTree = @import("middleware/origin.zig").DecisionTree;
pub const OriginHashMatcher = @import("middleware/origin.zig").HashMatcher;
pub const Timeout = @import("middleware/timeout.zig").Timeout;
pub const Etag = @import("middleware/etag.zig").Etag;
pub const RequestId = @import("middleware/request_id.zig").RequestId;
pub const SecurityHeaders = @import("middleware/security_headers.zig").SecurityHeaders;
