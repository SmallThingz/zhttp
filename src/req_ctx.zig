const std = @import("std");

pub const ST = struct {
    name: []const u8,
    T: type,
};

fn reqBasePtr(req_any: anytype) @TypeOf(switch (@typeInfo(@TypeOf(req_any))) {
    .pointer => req_any._base,
    else => req_any._base,
}) {
    return switch (@typeInfo(@TypeOf(req_any))) {
        .pointer => req_any._base,
        else => req_any._base,
    };
}

fn reqPath(req_any: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(req_any))) {
        .pointer => req_any.path,
        else => req_any.path,
    };
}

fn reqMethod(req_any: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(req_any))) {
        .pointer => req_any.method,
        else => req_any.method,
    };
}

fn assertTupleWithReq(comptime ParamsT: type) usize {
    const info = @typeInfo(ParamsT);
    if (info != .@"struct" or !info.@"struct".is_tuple or info.@"struct".fields.len == 0) {
        @compileError("ReqCtx.call params must be a non-empty tuple whose first item is req");
    }
    return info.@"struct".fields.len;
}

pub fn ReqCtx(comptime Response: type) type {
    return struct {
        const Self = @This();
        pub const HandlerFn = *const fn (comptime rctx: Self, req: anytype) Response;

        handler: HandlerFn,
        middlewares: []const type,
        path: []const ST,
        query: []const ST,
        headers: []const ST,
        middleware_contexts: []const ST,
        idx: usize,

        _base_req_type: type,

        pub fn withIdx(comptime self: Self, comptime next_idx: usize) Self {
            return .{
                .handler = self.handler,
                .middlewares = self.middlewares,
                .path = self.path,
                .query = self.query,
                .headers = self.headers,
                .middleware_contexts = self.middleware_contexts,
                .idx = next_idx,
                ._base_req_type = self._base_req_type,
            };
        }

        fn invoke(comptime self: Self, req: self.T()) Response {
            if (self.idx < self.middlewares.len) {
                const Mw = self.middlewares[self.idx];
                return @call(.auto, Mw.call, .{ self, req });
            }
            return @call(.auto, self.handler, .{ self, req });
        }

        pub fn T(comptime self: Self) type {
            const BaseReq = self._base_req_type;
            const Ctx = self;
            return struct {
                _base: *BaseReq,
                path: []const u8,
                method: []const u8,

                const ReqSelf = @This();

                pub fn raw(self2: ReqSelf) *BaseReq {
                    return self2._base;
                }

                pub fn allocator(self2: ReqSelf) std.mem.Allocator {
                    return Ctx.call(std.mem.Allocator, "allocator", .{self2});
                }

                pub fn io(self2: ReqSelf) std.Io {
                    return Ctx.call(std.Io, "io", .{self2});
                }

                pub fn base(self2: ReqSelf) *const @TypeOf(self2._base.baseConst().*) {
                    return Ctx.call(*const @TypeOf(self2._base.baseConst().*), "baseConst", .{self2});
                }

                pub fn baseConst(self2: ReqSelf) *const @TypeOf(self2._base.baseConst().*) {
                    return Ctx.call(*const @TypeOf(self2._base.baseConst().*), "baseConst", .{self2});
                }

                pub fn baseMut(self2: ReqSelf) *@TypeOf(self2._base.base().*) {
                    return Ctx.call(*@TypeOf(self2._base.base().*), "base", .{self2});
                }

                pub fn ctx(self2: ReqSelf) @TypeOf(self2._base.ctx()) {
                    return Ctx.call(@TypeOf(self2._base.ctx()), "ctx", .{self2});
                }

                pub fn ctxConst(self2: ReqSelf) @TypeOf(self2._base.ctxConst()) {
                    return Ctx.call(@TypeOf(self2._base.ctxConst()), "ctxConst", .{self2});
                }

                pub fn mwCtxMut(self2: ReqSelf) *@TypeOf(self2._base.mwCtxMut().*) {
                    return Ctx.call(*@TypeOf(self2._base.mwCtxMut().*), "mwCtxMut", .{self2});
                }

                pub fn mwCtxConst(self2: ReqSelf) *const @TypeOf(self2._base.mwCtxConst().*) {
                    return Ctx.call(*const @TypeOf(self2._base.mwCtxConst().*), "mwCtxConst", .{self2});
                }

                pub fn keepAlive(self2: ReqSelf) bool {
                    return Ctx.call(bool, "keepAlive", .{self2});
                }

                pub fn rawPath(self2: ReqSelf) []const u8 {
                    return Ctx.call([]const u8, "rawPath", .{self2});
                }

                pub fn header(self2: ReqSelf, comptime field: @EnumLiteral()) @TypeOf(self2._base.header(field)) {
                    return Ctx.call(@TypeOf(self2._base.header(field)), "header", .{ self2, field });
                }

                pub fn queryParam(self2: ReqSelf, comptime field: @EnumLiteral()) @TypeOf(self2._base.queryParam(field)) {
                    return Ctx.call(@TypeOf(self2._base.queryParam(field)), "queryParam", .{ self2, field });
                }

                pub fn paramValue(self2: ReqSelf, comptime field: @EnumLiteral()) @TypeOf(self2._base.paramValue(field)) {
                    return Ctx.call(@TypeOf(self2._base.paramValue(field)), "paramValue", .{ self2, field });
                }

                pub fn middlewareData(self2: ReqSelf, comptime name: anytype) @TypeOf(self2._base.middlewareData(name)) {
                    return Ctx.call(@TypeOf(self2._base.middlewareData(name)), "middlewareData", .{ self2, name });
                }

                pub fn middlewareDataConst(self2: ReqSelf, comptime name: anytype) @TypeOf(self2._base.middlewareDataConst(name)) {
                    return Ctx.call(@TypeOf(self2._base.middlewareDataConst(name)), "middlewareDataConst", .{ self2, name });
                }

                pub fn bodyAll(self2: ReqSelf, max_bytes: usize) @TypeOf(self2._base.bodyAll(max_bytes)) {
                    return Ctx.call(@TypeOf(self2._base.bodyAll(max_bytes)), "bodyAll", .{ self2, max_bytes });
                }

                pub fn discardUnreadBody(self2: ReqSelf) @TypeOf(self2._base.discardUnreadBody()) {
                    return Ctx.call(@TypeOf(self2._base.discardUnreadBody()), "discardUnreadBody", .{self2});
                }
            };
        }

        pub fn call(comptime self: Self, comptime ReturnT: type, comptime func_name: []const u8, params: anytype) ReturnT {
            const params_len = comptime assertTupleWithReq(@TypeOf(params));

            const BaseReq = self._base_req_type;
            if (!@hasDecl(BaseReq, func_name)) {
                @compileError("request method '" ++ func_name ++ "' not found on base request type");
            }

            const req0 = @field(params, "0");
            const req_base = reqBasePtr(req0);
            const path = reqPath(req0);
            const method = reqMethod(req0);

            comptime var i: usize = self.idx;
            inline while (i > 0) : (i -= 1) {
                const mw_index: usize = i - 1;
                const Mw = self.middlewares[mw_index];
                if (!@hasDecl(Mw, "Override")) continue;

                const target_ctx = self.withIdx(mw_index);
                const Ov = Mw.Override(target_ctx);
                if (!@hasDecl(Ov, func_name)) continue;

                const ov_fn = @field(Ov, func_name);
                const fn_info = @typeInfo(@TypeOf(ov_fn)).@"fn";
                if (fn_info.params.len != params_len) {
                    @compileError("override function parameter count must match base request method '" ++ func_name ++ "'");
                }
                const p0t = fn_info.params[0].type orelse @compileError("override req param type must be explicit");
                const TargetReq = target_ctx.T();
                var req_wrapped: TargetReq = .{
                    ._base = req_base,
                    .path = path,
                    .method = method,
                };

                if (params_len == 1) {
                    if (p0t == TargetReq) return @as(ReturnT, @call(.auto, ov_fn, .{req_wrapped}));
                    if (p0t == *TargetReq) return @as(ReturnT, @call(.auto, ov_fn, .{&req_wrapped}));
                    if (p0t == *const TargetReq) return @as(ReturnT, @call(.auto, ov_fn, .{@as(*const TargetReq, &req_wrapped)}));
                    @compileError("override first param must be req, *req, or *const req");
                }

                if (params_len == 2) {
                    const arg1 = @field(params, "1");
                    if (p0t == TargetReq) return @as(ReturnT, @call(.auto, ov_fn, .{ req_wrapped, arg1 }));
                    if (p0t == *TargetReq) return @as(ReturnT, @call(.auto, ov_fn, .{ &req_wrapped, arg1 }));
                    if (p0t == *const TargetReq) return @as(ReturnT, @call(.auto, ov_fn, .{ @as(*const TargetReq, &req_wrapped), arg1 }));
                    @compileError("override first param must be req, *req, or *const req");
                }

                @compileError("ReqCtx.call supports request methods with at most one argument beyond req");
            }

            const base_fn = @field(BaseReq, func_name);
            if (params_len == 1) {
                return @as(ReturnT, @call(.auto, base_fn, .{req_base}));
            }
            if (params_len == 2) {
                const arg1 = @field(params, "1");
                return @as(ReturnT, @call(.auto, base_fn, .{ req_base, arg1 }));
            }
            @compileError("ReqCtx.call supports request methods with at most one argument beyond req");
        }

        pub fn next(comptime self: Self, req: self.T()) Response {
            const next_idx = self.idx + 1;
            if (next_idx > self.middlewares.len) {
                return self.invoke(req);
            }
            const child = self.withIdx(next_idx);
            const ChildReq = child.T();
            const child_req: ChildReq = .{
                ._base = req._base,
                .path = req.path,
                .method = req.method,
            };
            return child.invoke(child_req);
        }

        pub fn run(comptime self: Self, req: self.T()) Response {
            return self.invoke(req);
        }
    };
}
