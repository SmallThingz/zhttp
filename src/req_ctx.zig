const std = @import("std");
const response = @import("response.zig");

comptime {
    @setEvalBranchQuota(200_000);
}

pub const ST = struct {
    /// Stores `name`.
    name: []const u8,
    /// Stores `T`.
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

pub const ReqCtx = struct {
    const Self = @This();

    /// Stores `handler`.
    handler: type,
    /// Stores `middlewares`.
    middlewares: []const type,
    /// Stores `path`.
    path: []const ST,
    /// Stores `query`.
    query: []const ST,
    /// Stores `headers`.
    headers: []const ST,
    /// Stores `middleware_contexts`.
    middleware_contexts: []const ST,
    /// Stores `idx`.
    idx: usize,

    /// Stores internal `_base_req_type` state.
    _base_req_type: type,
    /// Stores internal `_server_type` state.
    _server_type: type = void,

    fn payloadType(comptime ReturnT: type) type {
        return switch (@typeInfo(ReturnT)) {
            .error_union => |eu| eu.payload,
            else => ReturnT,
        };
    }

    fn assertHandlerType(comptime Handler: type) void {
        if (!@hasDecl(Handler, "function")) {
            @compileError("ReqCtx.handler must expose `pub const function = <handler>`");
        }
        const fn_t = @TypeOf(@field(Handler, "function"));
        if (@typeInfo(fn_t) != .@"fn") {
            @compileError("ReqCtx.handler.function must be a function");
        }
    }

    fn handlerFn(comptime Handler: type) type {
        return @TypeOf(@field(Handler, "function"));
    }

    fn handlerEntry(comptime Handler: type) handlerFn(Handler) {
        return @field(Handler, "function");
    }

    /// Implements with idx.
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
            ._server_type = self._server_type,
        };
    }

    /// Returns the concrete server type associated with this request context.
    pub fn Server(comptime self: Self) type {
        return self._server_type;
    }

    /// Returns a concrete response type for a selected body representation.
    pub fn Response(comptime self: Self, comptime Body: type) type {
        _ = self;
        return response.Response(Body);
    }

    /// Returns the inferred endpoint/middleware response type for this request context.
    fn InferredResponse(comptime self: Self) type {
        assertHandlerType(self.handler);
        const HandlerReq = self.T();
        const entry = handlerEntry(self.handler);
        const handler_ret = @TypeOf(@call(.auto, entry, .{ self, @as(HandlerReq, undefined) }));
        return payloadType(handler_ret);
    }

    /// Executes either the current middleware or the terminal endpoint function.
    fn invoke(comptime self: Self, req: self.T()) !self.InferredResponse() {
        if (self.idx < self.middlewares.len) {
            const Mw = self.middlewares[self.idx];
            return @call(.auto, Mw.call, .{ self, req });
        }
        const entry = handlerEntry(self.handler);
        return @call(.auto, entry, .{ self, req });
    }

    /// Returns the request wrapper type for this request context.
    pub fn T(comptime self: Self) type {
        const BaseReq = self._base_req_type;
        const Ctx = self;
        return struct {
            /// Stores internal `_base` state.
            _base: *BaseReq,
            /// Stores `path`.
            path: []const u8,
            /// Stores `method`.
            method: []const u8,

            const ReqSelf = @This();

            /// Implements raw.
            pub fn raw(self2: ReqSelf) *BaseReq {
                return self2._base;
            }

            /// Implements allocator.
            pub fn allocator(self2: ReqSelf) std.mem.Allocator {
                return Ctx.call(std.mem.Allocator, "allocator", .{self2});
            }

            /// Implements io.
            pub fn io(self2: ReqSelf) std.Io {
                return Ctx.call(std.Io, "io", .{self2});
            }

            /// Implements base.
            pub fn base(self2: ReqSelf) *const @TypeOf(self2._base.baseConst().*) {
                return Ctx.call(*const @TypeOf(self2._base.baseConst().*), "baseConst", .{self2});
            }

            /// Implements base const.
            pub fn baseConst(self2: ReqSelf) *const @TypeOf(self2._base.baseConst().*) {
                return Ctx.call(*const @TypeOf(self2._base.baseConst().*), "baseConst", .{self2});
            }

            /// Implements base mut.
            pub fn baseMut(self2: ReqSelf) *@TypeOf(self2._base.base().*) {
                return Ctx.call(*@TypeOf(self2._base.base().*), "base", .{self2});
            }

            /// Implements ctx.
            pub fn ctx(self2: ReqSelf) @TypeOf(self2._base.ctx()) {
                return Ctx.call(@TypeOf(self2._base.ctx()), "ctx", .{self2});
            }

            /// Implements ctx const.
            pub fn ctxConst(self2: ReqSelf) @TypeOf(self2._base.ctxConst()) {
                return Ctx.call(@TypeOf(self2._base.ctxConst()), "ctxConst", .{self2});
            }

            /// Implements mw ctx mut.
            pub fn mwCtxMut(self2: ReqSelf) *@TypeOf(self2._base.mwCtxMut().*) {
                return Ctx.call(*@TypeOf(self2._base.mwCtxMut().*), "mwCtxMut", .{self2});
            }

            /// Implements mw ctx const.
            pub fn mwCtxConst(self2: ReqSelf) *const @TypeOf(self2._base.mwCtxConst().*) {
                return Ctx.call(*const @TypeOf(self2._base.mwCtxConst().*), "mwCtxConst", .{self2});
            }

            /// Implements mw static ctx mut.
            pub fn mwStaticCtxMut(self2: ReqSelf) *@TypeOf(self2._base.mwStaticCtxMut().*) {
                return Ctx.call(*@TypeOf(self2._base.mwStaticCtxMut().*), "mwStaticCtxMut", .{self2});
            }

            /// Implements mw static ctx const.
            pub fn mwStaticCtxConst(self2: ReqSelf) *const @TypeOf(self2._base.mwStaticCtxConst().*) {
                return Ctx.call(*const @TypeOf(self2._base.mwStaticCtxConst().*), "mwStaticCtxConst", .{self2});
            }

            /// Implements keep alive.
            pub fn keepAlive(self2: ReqSelf) bool {
                return Ctx.call(bool, "keepAlive", .{self2});
            }

            /// Implements header.
            pub fn header(self2: ReqSelf, comptime field: @EnumLiteral()) @TypeOf(self2._base.header(field)) {
                return Ctx.call(@TypeOf(self2._base.header(field)), "header", .{ self2, field });
            }

            /// Implements query param.
            pub fn queryParam(self2: ReqSelf, comptime field: @EnumLiteral()) @TypeOf(self2._base.queryParam(field)) {
                return Ctx.call(@TypeOf(self2._base.queryParam(field)), "queryParam", .{ self2, field });
            }

            /// Implements param value.
            pub fn paramValue(self2: ReqSelf, comptime field: @EnumLiteral()) @TypeOf(self2._base.paramValue(field)) {
                return Ctx.call(@TypeOf(self2._base.paramValue(field)), "paramValue", .{ self2, field });
            }

            /// Implements middleware data.
            pub fn middlewareData(self2: ReqSelf, comptime name: anytype) @TypeOf(self2._base.middlewareData(name)) {
                return Ctx.call(@TypeOf(self2._base.middlewareData(name)), "middlewareData", .{ self2, name });
            }

            /// Implements middleware data const.
            pub fn middlewareDataConst(self2: ReqSelf, comptime name: anytype) @TypeOf(self2._base.middlewareDataConst(name)) {
                return Ctx.call(@TypeOf(self2._base.middlewareDataConst(name)), "middlewareDataConst", .{ self2, name });
            }

            /// Implements middleware static.
            pub fn middlewareStatic(self2: ReqSelf, comptime name: anytype) @TypeOf(self2._base.middlewareStatic(name)) {
                return Ctx.call(@TypeOf(self2._base.middlewareStatic(name)), "middlewareStatic", .{ self2, name });
            }

            /// Implements middleware static const.
            pub fn middlewareStaticConst(self2: ReqSelf, comptime name: anytype) @TypeOf(self2._base.middlewareStaticConst(name)) {
                return Ctx.call(@TypeOf(self2._base.middlewareStaticConst(name)), "middlewareStaticConst", .{ self2, name });
            }

            /// Returns the owning server pointer for the active request.
            pub fn server(self2: ReqSelf) *Ctx.Server() {
                const ServerT = Ctx.Server();
                if (ServerT == void) @compileError("ReqCtx.Server() is void for this request context");
                return Ctx.call(*ServerT, "server", .{self2});
            }

            /// Returns the owning server pointer for the active request.
            pub fn serverConst(self2: ReqSelf) *const Ctx.Server() {
                return @as(*const Ctx.Server(), self2.server());
            }

            /// Implements body all.
            pub fn bodyAll(self2: ReqSelf, max_bytes: usize) @TypeOf(self2._base.bodyAll(max_bytes)) {
                return Ctx.call(@TypeOf(self2._base.bodyAll(max_bytes)), "bodyAll", .{ self2, max_bytes });
            }

            /// Implements discard unread body.
            pub fn discardUnreadBody(self2: ReqSelf) @TypeOf(self2._base.discardUnreadBody()) {
                return Ctx.call(@TypeOf(self2._base.discardUnreadBody()), "discardUnreadBody", .{self2});
            }
        };
    }

    /// Handles a middleware invocation for the current request context.
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

    /// Invokes the next handler in the middleware chain.
    pub fn next(comptime self: Self, req: self.T()) !self.InferredResponse() {
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

    /// Runs this component.
    pub fn run(comptime self: Self, req: self.T()) !self.InferredResponse() {
        return self.invoke(req);
    }
};

test "ReqCtx: run/next/override chain and server access work" {
    const testing = std.testing;
    const Res = response.Res;

    const FakeServer = struct {
        tag: u8,
    };

    const FakeBase = struct {
        const InnerBase = struct {
            touched: bool = false,
        };
        const AppCtx = struct {
            value: u8 = 3,
        };
        const MwCtx = struct {
            dummy: u8 = 0,
        };
        const MwStaticCtx = struct {
            dummy: u8 = 0,
        };

        allocator_value: std.mem.Allocator,
        io_value: std.Io,
        inner: InnerBase = .{},
        app_ctx: AppCtx = .{},
        mw_ctx: MwCtx = .{},
        mw_static_ctx: MwStaticCtx = .{},
        server_ptr: *FakeServer,
        call_trace: [4]u8 = .{ 0, 0, 0, 0 },
        trace_len: usize = 0,
        override_seen: bool = false,

        pub fn allocator(self: *@This()) std.mem.Allocator {
            return self.allocator_value;
        }
        pub fn io(self: *@This()) std.Io {
            return self.io_value;
        }
        pub fn base(self: *@This()) *InnerBase {
            return &self.inner;
        }
        pub fn baseConst(self: *@This()) *const InnerBase {
            return &self.inner;
        }
        pub fn ctx(self: *@This()) *AppCtx {
            return &self.app_ctx;
        }
        pub fn ctxConst(self: *@This()) *const AppCtx {
            return &self.app_ctx;
        }
        pub fn mwCtxMut(self: *@This()) *MwCtx {
            return &self.mw_ctx;
        }
        pub fn mwCtxConst(self: *@This()) *const MwCtx {
            return &self.mw_ctx;
        }
        pub fn mwStaticCtxMut(self: *@This()) *MwStaticCtx {
            return &self.mw_static_ctx;
        }
        pub fn mwStaticCtxConst(self: *@This()) *const MwStaticCtx {
            return &self.mw_static_ctx;
        }
        pub fn keepAlive(_: *@This()) bool {
            return true;
        }
        pub fn header(_: *@This(), comptime _: anytype) ?[]const u8 {
            return null;
        }
        pub fn queryParam(_: *@This(), comptime _: anytype) ?[]const u8 {
            return null;
        }
        pub fn paramValue(_: *@This(), comptime _: anytype) ?[]const u8 {
            return null;
        }
        pub fn middlewareData(_: *@This(), comptime _: anytype) *MwCtx {
            unreachable;
        }
        pub fn middlewareDataConst(_: *@This(), comptime _: anytype) *const MwCtx {
            unreachable;
        }
        pub fn middlewareStatic(_: *@This(), comptime _: anytype) *MwStaticCtx {
            unreachable;
        }
        pub fn middlewareStaticConst(_: *@This(), comptime _: anytype) *const MwStaticCtx {
            unreachable;
        }
        pub fn server(self: *@This()) *FakeServer {
            return self.server_ptr;
        }
        pub fn bodyAll(self: *@This(), _: usize) error{Dummy}![]const u8 {
            self.override_seen = false;
            return "base";
        }
        pub fn discardUnreadBody(_: *@This()) error{Dummy}!void {}
    };

    const M1 = struct {
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            req.raw().call_trace[req.raw().trace_len] = '1';
            req.raw().trace_len += 1;
            return rctx.next(req);
        }

        pub fn Override(comptime rctx: ReqCtx) type {
            return struct {
                pub fn bodyAll(req: *rctx.T(), max_bytes: usize) error{Dummy}![]const u8 {
                    _ = max_bytes;
                    req.raw().override_seen = true;
                    return "mw1";
                }
            };
        }
    };

    const M2 = struct {
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !Res {
            req.raw().call_trace[req.raw().trace_len] = '2';
            req.raw().trace_len += 1;
            return rctx.next(req);
        }

        pub fn Override(comptime rctx: ReqCtx) type {
            return struct {
                pub fn bodyAll(req: *rctx.T(), max_bytes: usize) error{Dummy}![]const u8 {
                    req.raw().call_trace[req.raw().trace_len] = 'o';
                    req.raw().trace_len += 1;
                    return req.bodyAll(max_bytes);
                }
            };
        }
    };

    const Handler = struct {
        pub const function = call;

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !rctx.Response([]const u8) {
            try testing.expect(rctx.Server() == FakeServer);
            try testing.expectEqual(@as(u8, 9), req.server().tag);
            req.baseMut().touched = true;
            const body = try req.bodyAll(128);
            req.raw().call_trace[req.raw().trace_len] = 'h';
            req.raw().trace_len += 1;
            return Res.text(200, body);
        }
    };

    var server: FakeServer = .{ .tag = 9 };
    var base: FakeBase = .{
        .allocator_value = testing.allocator,
        .io_value = testing.io,
        .server_ptr = &server,
    };

    const rctx: ReqCtx = .{
        .handler = Handler,
        .middlewares = &.{ M1, M2 },
        .path = &.{},
        .query = &.{},
        .headers = &.{},
        .middleware_contexts = &.{},
        .idx = 0,
        ._base_req_type = FakeBase,
        ._server_type = FakeServer,
    };

    const ReqT = rctx.T();
    const req: ReqT = .{
        ._base = &base,
        .path = "/items/1",
        .method = "GET",
    };

    const res = try rctx.run(req);
    try testing.expectEqualStrings("mw1", res.body);
    try testing.expect(base.inner.touched);
    try testing.expect(base.override_seen);
    try testing.expectEqual(@as(usize, 4), base.trace_len);
    try testing.expectEqualStrings("12oh", base.call_trace[0..base.trace_len]);
}
