const std = @import("std");
const parse = @import("parse.zig");
const req_ctx = @import("req_ctx.zig");

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
pub fn needsQuery(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(100000);
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
pub fn needsParams(comptime mws: anytype) type {
    comptime {
        @setEvalBranchQuota(100000);
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

/// Returns middleware context schema entries used by `ReqCtx`.
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
