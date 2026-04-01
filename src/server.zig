const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const response = @import("response.zig");
const request = @import("request.zig");
const upgrade_mod = @import("upgrade.zig");
const ReqCtx = @import("req_ctx.zig").ReqCtx;
const router = @import("router.zig");
const middleware = @import("middleware.zig");
const operations = @import("operations.zig");
const parse = @import("parse.zig");
const zws = @import("zwebsocket");

fn setTcpNoDelay(stream: *const std.Io.net.Stream) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    var one: i32 = 1;
    std.posix.setsockopt(
        stream.socket.handle,
        @intCast(linux.IPPROTO.TCP),
        linux.TCP.NODELAY,
        std.mem.asBytes(&one),
    ) catch {};
}

pub const Config = struct {
    /// Kernel listen backlog used when creating the server socket.
    listen_backlog: u31 = 4096,
    /// Number of listening sockets bound to the same address. On POSIX this
    /// uses the std `reuse_address` path, which also enables `SO_REUSEPORT`.
    listener_shards: usize = 1,
    /// Per-connection read buffer size.
    read_buffer: usize = 8 * 1024,
    /// Per-connection write buffer size. Zero disables buffering.
    write_buffer: usize = 4 * 1024,
    /// Enable TCP_NODELAY (disables Nagle). Off by default.
    tcp_nodelay: bool = false,
    /// Use abortive close (`SO_LINGER {on=1, linger=0}`) for transport closes.
    abortive_close: bool = false,
    /// Maximum request line length (bytes, including `\r\n`).
    max_request_line: usize = 8 * 1024,
    /// Maximum bytes allowed for a single header line (including line ending).
    max_single_header_size: usize = 8 * 1024,
    /// Maximum total header bytes (bytes, including line endings).
    max_header_bytes: usize = 32 * 1024,
    /// Maximum bytes the arena can retain after a reset
    arena_reset_limit: usize = 1024 * 1024,
    /// Maximum accepted connections handled by a temporary worker before it exits.
    temp_worker_connection_limit: usize = 1024,
    /// Enables temporary worker spawning under sustained pressure.
    temp_workers: bool = true,
    /// Maximum number of temporary workers alive at once. Zero means auto (= permanent worker count).
    max_temp_workers: usize = 0,
};

fn configField(comptime cfg: anytype, comptime name: []const u8) @FieldType(Config, name) {
    return @field(if (@hasField(@TypeOf(cfg), name)) cfg else Config{}, name);
}

/// Server definition options (`def`) are provided at comptime.
///
/// Supported fields:
/// - `Context: type`      Optional user context type. Defaults to `void`.
/// - `middlewares: tuple` Optional global middleware types. Defaults to `.{}`.
///                        Each middleware type must satisfy `middleware.info(...)` shape.
/// - `routes: struct`     Required routes tuple/struct: `.{ zhttp.get(...), ... }`.
///                        Each endpoint must expose `Info` + `call` with zhttp endpoint shape.
/// - `operations: tuple`  Optional route-operation types executed at comptime in tuple order.
///                        Each operation exposes `operation(opctx, router)` and optional `maxAddedRoutes(...)`.
/// - `config: struct`     Optional config overrides (fields match `zhttp.server.Config`).
/// - `error_handler`      Optional fallback transport/dispatch error handler:
///                        `fn(*Server, *Io.Writer, comptime ErrorSet: type, err: ErrorSet) router.Action`.
/// - `not_found_handler`  Optional fallback endpoint type override for route misses.
pub fn Server(comptime def: anytype) type {
    if (!@hasField(@TypeOf(def), "routes")) @compileError("Server definition must include `.routes = .{ ... }`");
    const Context = if (@hasField(@TypeOf(def), "Context")) def.Context else void;
    const cfg = if (@hasField(@TypeOf(def), "config")) def.config else .{};

    const Conf: Config = .{
        .listen_backlog = configField(cfg, "listen_backlog"),
        .listener_shards = configField(cfg, "listener_shards"),
        .read_buffer = configField(cfg, "read_buffer"),
        .write_buffer = configField(cfg, "write_buffer"),
        .tcp_nodelay = configField(cfg, "tcp_nodelay"),
        .abortive_close = configField(cfg, "abortive_close"),
        .max_request_line = configField(cfg, "max_request_line"),
        .max_single_header_size = configField(cfg, "max_single_header_size"),
        .max_header_bytes = configField(cfg, "max_header_bytes"),
        .arena_reset_limit = configField(cfg, "arena_reset_limit"),
        .temp_worker_connection_limit = configField(cfg, "temp_worker_connection_limit"),
        .temp_workers = configField(cfg, "temp_workers"),
        .max_temp_workers = configField(cfg, "max_temp_workers"),
    };
    comptime {
        if (Conf.listener_shards == 0) {
            @compileError("server config invalid: listener_shards must be >= 1");
        }
        if (Conf.read_buffer < Conf.max_request_line) {
            @compileError("server config invalid: read_buffer must be >= max_request_line");
        }
        if (Conf.read_buffer < Conf.max_single_header_size) {
            @compileError("server config invalid: read_buffer must be >= max_single_header_size");
        }
        if (Conf.max_header_bytes < Conf.max_single_header_size) {
            @compileError("server config invalid: max_header_bytes must be >= max_single_header_size");
        }
    }

    const DefT = @TypeOf(def);
    const Middlewares = if (@hasField(DefT, "middlewares")) def.middlewares else .{};
    const Operations = if (@hasField(DefT, "operations")) def.operations else .{};
    const Routes = operations.apply(def.routes, Middlewares, Operations);
    const GlobalMwList = comptime middleware.typeList(Middlewares);
    const route_fields = @typeInfo(@TypeOf(Routes)).@"struct".fields;
    const RouteStaticCtxTuple = comptime blk: {
        var Ts: [route_fields.len]type = undefined;
        for (route_fields, 0..) |f, i| {
            const rd = @field(Routes, f.name);
            const MwList = middleware.concatTypeLists(GlobalMwList, rd.middlewares);
            Ts[i] = middleware.staticContextType(MwList);
        }
        break :blk std.meta.Tuple(&Ts);
    };
    const Compiled = router.Compiled(Context, Routes, Middlewares);
    const DefaultNotFound = struct {
        pub const Info: router.EndpointInfo = .{};
        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
            _ = req;
            return response.Res.text(404, "not found");
        }
    };
    const NotFoundHandler = if (@hasField(DefT, "not_found_handler")) def.not_found_handler else DefaultNotFound;
    const NotFoundRoute = router.get("/", NotFoundHandler);
    const NotFoundCompiled = router.Compiled(Context, .{NotFoundRoute}, Middlewares);

    return struct {
        io: Io,
        gpa: Allocator,
        listener: std.Io.net.Server,
        extra_listeners: [Conf.listener_shards - 1]std.Io.net.Server,
        lifecycle: std.atomic.Value(Lifecycle),
        group: Io.Group = .init,
        permanent_worker_count: std.atomic.Value(usize),
        busy_workers: std.atomic.Value(usize),
        live_temp_workers: std.atomic.Value(usize),
        ctx: if (Context == void) void else *Context,
        route_static_ctx: RouteStaticCtxTuple,

        const Self = @This();
        pub const config = Conf;
        pub const RunArgs = struct {
            gpa: Allocator,
            io: Io,
            address: std.Io.net.IpAddress,
            ctx: if (Context == void) void else *Context,
            /// Number of long-lived accept workers. Zero means auto.
            permanent_workers: usize = 0,
            /// When non-null, receives the bound local port after listen succeeds.
            actual_port_out: ?*u16 = null,
        };
        const InitError = @typeInfo(@typeInfo(@TypeOf(initOwned)).@"fn".return_type.?).error_union.error_set;
        const Lifecycle = enum(u8) {
            running,
            stopping,
            closed,
        };
        const Action = router.Action;
        const WorkerState = struct {
            arena: std.heap.ArenaAllocator,
            read_buf: [Conf.read_buffer]u8 = undefined,
            write_buf: [Conf.write_buffer]u8 = undefined,

            fn init(gpa: Allocator) WorkerState {
                return .{
                    .arena = std.heap.ArenaAllocator.init(gpa),
                };
            }

            fn deinit(self: *WorkerState) void {
                self.arena.deinit();
            }

            fn allocator(self: *WorkerState) Allocator {
                return self.arena.allocator();
            }

            fn reset(self: *WorkerState) void {
                _ = self.arena.reset(.{ .retain_with_limit = config.arena_reset_limit });
            }
        };
        const RouteFn = fn (
            server: *Self,
            state: *WorkerState,
            r: *Io.Reader,
            w: *Io.Writer,
            stream: *const std.Io.net.Stream,
            line: request.RequestLine,
            a: Allocator,
        ) Compiled.DispatchError!Action;
        const NotFoundFn = fn (
            server: *Self,
            state: *WorkerState,
            r: *Io.Reader,
            w: *Io.Writer,
            stream: *const std.Io.net.Stream,
            line: request.RequestLine,
            a: Allocator,
        ) NotFoundCompiled.DispatchError!Action;
        const DefaultErrorHandler = struct {
            fn call(server: *Self, w: *Io.Writer, comptime ErrorSet: type, _: ErrorSet) Action {
                server.writeSimple(w, 500, "internal error");
                return .close;
            }
        };
        const ErrorHandler = if (@hasField(DefT, "error_handler")) def.error_handler else DefaultErrorHandler.call;
        pub const RouteCount: usize = route_fields.len;
        pub const RouteDeclList: [route_fields.len]router.RouteDecl = blk: {
            var out: [route_fields.len]router.RouteDecl = undefined;
            for (route_fields, 0..) |f, i| {
                out[i] = @field(Routes, f.name);
            }
            break :blk out;
        };

        fn routeFieldName(comptime route_index: usize) []const u8 {
            if (route_index >= route_fields.len) {
                @compileError("route index is out of bounds");
            }
            return route_fields[route_index].name;
        }

        /// Returns all declared route metadata.
        pub fn routeDecls(_: *const Self) []const router.RouteDecl {
            return RouteDeclList[0..];
        }

        /// Returns declared route metadata by compile-time index.
        pub fn routeDecl(comptime route_index: usize) router.RouteDecl {
            return RouteDeclList[route_index];
        }

        /// Returns compile-time route index for a method/pattern pair.
        pub fn routeIndex(comptime method: []const u8, comptime pattern: []const u8) usize {
            inline for (route_fields, 0..) |f, i| {
                const rd = @field(Routes, f.name);
                if (std.mem.eql(u8, rd.method, method) and std.mem.eql(u8, rd.pattern, pattern)) return i;
            }
            @compileError("route not found for method='" ++ method ++ "' pattern='" ++ pattern ++ "'");
        }

        /// Returns the static-context type for a compile-time route index.
        pub fn RouteStaticType(comptime route_index: usize) type {
            return @TypeOf(@field(@as(RouteStaticCtxTuple, undefined), routeFieldName(route_index)));
        }

        /// Returns pointer to all route static contexts.
        pub fn routeStaticTuple(self: *Self) *RouteStaticCtxTuple {
            return &self.route_static_ctx;
        }

        /// Returns const pointer to all route static contexts.
        pub fn routeStaticTupleConst(self: *const Self) *const RouteStaticCtxTuple {
            return &self.route_static_ctx;
        }

        /// Returns pointer to a route static context by compile-time index.
        ///
        /// This accessor is lock-free: synchronization is the caller's
        /// responsibility.
        pub fn routeStatic(self: *Self, comptime route_index: usize) *RouteStaticType(route_index) {
            return &@field(self.route_static_ctx, routeFieldName(route_index));
        }

        /// Returns const pointer to a route static context by compile-time index.
        ///
        /// This accessor is lock-free: synchronization is the caller's
        /// responsibility.
        pub fn routeStaticConst(self: *const Self, comptime route_index: usize) *const RouteStaticType(route_index) {
            return &@field(self.route_static_ctx, routeFieldName(route_index));
        }

        fn initRouteStaticContexts(io: Io, gpa: Allocator) !RouteStaticCtxTuple {
            var out: RouteStaticCtxTuple = undefined;
            var initialized_count: usize = 0;
            errdefer {
                inline for (route_fields, 0..) |f, i| {
                    if (i < initialized_count) {
                        const StaticCtx = @TypeOf(@field(out, f.name));
                        middleware.deinitStaticContext(StaticCtx, io, gpa, &@field(out, f.name));
                    }
                }
            }
            inline for (route_fields, 0..) |f, i| {
                const rd = @field(Routes, f.name);
                const StaticCtx = comptime @TypeOf(@field(out, f.name));
                @field(out, f.name) = try middleware.initStaticContext(StaticCtx, io, gpa, rd);
                initialized_count = i + 1;
            }
            return out;
        }

        fn deinitRouteStaticContexts(self: *Self) void {
            inline for (route_fields) |f| {
                const StaticCtx = @TypeOf(@field(self.route_static_ctx, f.name));
                middleware.deinitStaticContext(StaticCtx, self.io, self.gpa, &@field(self.route_static_ctx, f.name));
            }
        }

        /// Initializes a bound server instance for internal use and white-box tests.
        fn initOwned(
            gpa: Allocator,
            io: Io,
            address: std.Io.net.IpAddress,
            ctx: if (Context == void) void else *Context,
        ) !Self {
            var listener = try std.Io.net.IpAddress.listen(&address, io, .{
                .kernel_backlog = Conf.listen_backlog,
                .reuse_address = true,
            });
            errdefer listener.deinit(io);
            var extra_listeners: [Conf.listener_shards - 1]std.Io.net.Server = undefined;
            errdefer {
                inline for (0..Conf.listener_shards - 1) |i| {
                    extra_listeners[i].deinit(io);
                }
            }
            inline for (0..Conf.listener_shards - 1) |i| {
                extra_listeners[i] = try std.Io.net.IpAddress.listen(&address, io, .{
                    .kernel_backlog = Conf.listen_backlog,
                    .reuse_address = true,
                });
            }
            const route_static_ctx = try initRouteStaticContexts(io, gpa);
            return .{
                .io = io,
                .gpa = gpa,
                .listener = listener,
                .extra_listeners = extra_listeners,
                .lifecycle = std.atomic.Value(Lifecycle).init(.running),
                .permanent_worker_count = std.atomic.Value(usize).init(0),
                .busy_workers = std.atomic.Value(usize).init(0),
                .live_temp_workers = std.atomic.Value(usize).init(0),
                .ctx = ctx,
                .route_static_ctx = route_static_ctx,
            };
        }

        /// Stops accepting new connections.
        pub fn stop(self: *Self) void {
            if (self.lifecycle.cmpxchgStrong(.running, .stopping, .acq_rel, .acquire) != null) return;

            const wake_count = (self.permanent_worker_count.load(.acquire) + self.live_temp_workers.load(.acquire) + 1) * listenerShardCount();
            var i: usize = 0;
            while (i < wake_count) : (i += 1) {
                var wake = std.Io.net.IpAddress.connect(&self.listener.socket.address, self.io, .{ .mode = .stream }) catch null;
                if (wake) |*stream| stream.close(self.io);
            }
        }

        /// Releases resources held by this value.
        pub fn deinit(self: *Self) void {
            self.stop();
            self.group.await(self.io) catch {};
            // std.Io Group/Server resources must be released exactly once.
            if (self.lifecycle.swap(.closed, .acq_rel) != .closed) {
                self.deinitRouteStaticContexts();
                self.listener.deinit(self.io);
                inline for (0..Conf.listener_shards - 1) |i| {
                    self.extra_listeners[i].deinit(self.io);
                }
            }
        }

        /// Binds, runs, and tears down the server in one call.
        pub fn run(args: RunArgs) (InitError || Io.Cancelable)!void {
            var self = try initOwned(args.gpa, args.io, args.address, args.ctx);
            defer self.deinit();
            if (args.actual_port_out) |port_out| {
                port_out.* = self.listener.socket.address.getPort();
            }
            return self.serve(.{
                .permanent_workers = args.permanent_workers,
            });
        }

        const ServeOptions = struct {
            permanent_workers: usize = 0,
        };

        fn serve(self: *Self, opts: ServeOptions) Io.Cancelable!void {
            const permanent_workers = permanentWorkerCount(opts.permanent_workers);
            self.permanent_worker_count.store(permanent_workers, .release);
            var i: usize = 0;
            while (i < permanent_workers) : (i += 1) {
                self.group.concurrent(self.io, worker, .{ self, i % listenerShardCount() }) catch return error.Canceled;
            }
            if (Conf.temp_workers and maxTempWorkerCount(permanent_workers) != 0) {
                self.group.concurrent(self.io, spawnTempWorkers, .{self}) catch return error.Canceled;
            }
            self.group.await(self.io) catch {};
        }

        fn listenerShardCount() usize {
            return Conf.listener_shards;
        }

        fn permanentWorkerCount(runtime_count: usize) usize {
            if (runtime_count != 0) return runtime_count;
            const cpu_count = std.Thread.getCpuCount() catch 1;
            return @max(cpu_count * 2 - 1, 1);
        }

        fn maxTempWorkerCount(permanent_workers: usize) usize {
            return if (Conf.max_temp_workers == 0) permanent_workers else Conf.max_temp_workers;
        }

        fn listenerAt(self: *Self, shard_idx: usize) *std.Io.net.Server {
            if (comptime Conf.listener_shards == 1) return &self.listener;
            return if (shard_idx == 0) &self.listener else &self.extra_listeners[shard_idx - 1];
        }

        fn acceptOne(self: *Self, shard_idx: usize) Io.Cancelable!?std.Io.net.Stream {
            const stream = self.listenerAt(shard_idx).accept(self.io) catch |err| switch (err) {
                error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => return null,
                error.ConnectionAborted, error.BlockedByFirewall, error.ProtocolFailure => return null,
                error.SocketNotListening, error.Canceled => return error.Canceled,
                error.NetworkDown => return error.Canceled,
                error.WouldBlock => return error.Canceled,
                error.Unexpected => return error.Canceled,
            };
            if (self.lifecycle.load(.acquire) != .running) {
                stream.close(self.io);
                return error.Canceled;
            }
            return stream;
        }

        fn worker(self: *Self, shard_idx: usize) Io.Cancelable!void {
            var state = WorkerState.init(self.gpa);
            defer state.deinit();
            while (self.lifecycle.load(.acquire) == .running) {
                const stream = (try self.acceptOne(shard_idx)) orelse continue;
                if (Conf.temp_workers) _ = self.busy_workers.fetchAdd(1, .acq_rel);
                handleConn(self, &state, stream) catch |err| {
                    if (Conf.temp_workers) _ = self.busy_workers.fetchSub(1, .acq_rel);
                    switch (err) {
                        error.Canceled => return,
                    }
                };
                if (Conf.temp_workers) _ = self.busy_workers.fetchSub(1, .acq_rel);
                state.reset();
            }
        }

        fn tempWorker(self: *Self) Io.Cancelable!void {
            _ = self.live_temp_workers.fetchAdd(1, .acq_rel);
            defer _ = self.live_temp_workers.fetchSub(1, .acq_rel);
            var state = WorkerState.init(self.gpa);
            defer state.deinit();

            var accepted: usize = 0;
            const shard_idx = if (listenerShardCount() == 1) 0 else self.live_temp_workers.load(.acquire) % listenerShardCount();
            while (self.lifecycle.load(.acquire) == .running and accepted < Conf.temp_worker_connection_limit) {
                const stream = (try self.acceptOne(shard_idx)) orelse continue;
                accepted += 1;
                _ = self.busy_workers.fetchAdd(1, .acq_rel);
                handleConn(self, &state, stream) catch |err| {
                    _ = self.busy_workers.fetchSub(1, .acq_rel);
                    switch (err) {
                        error.Canceled => return,
                    }
                };
                _ = self.busy_workers.fetchSub(1, .acq_rel);
                state.reset();
            }
        }

        fn spawnTempWorkers(self: *Self) Io.Cancelable!void {
            while (self.lifecycle.load(.acquire) == .running) {
                const live_temp = self.live_temp_workers.load(.acquire);
                const busy = self.busy_workers.load(.acquire);
                const permanent_workers = self.permanent_worker_count.load(.acquire);
                const total_workers = permanent_workers + live_temp;
                if (live_temp < maxTempWorkerCount(permanent_workers) and busy >= total_workers) {
                    self.group.concurrent(self.io, tempWorker, .{self}) catch {};
                }
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(1), .awake) catch return;
            }
        }

        fn writeSimple(self: *Self, w: *Io.Writer, status: u16, body: []const u8) void {
            const res = response.Res.text(status, body);
            response.write(w, res, false, true) catch {};
            _ = self;
        }

        fn closeStream(self: *Self, stream: *const std.Io.net.Stream) void {
            if (Conf.abortive_close and builtin.os.tag != .windows) {
                const linger: std.posix.linger = .{ .onoff = 1, .linger = 0 };
                std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger)) catch {};
            }
            stream.close(self.io);
        }

        fn validateErrorHandler() void {
            const info = @typeInfo(@TypeOf(ErrorHandler));
            if (info != .@"fn") @compileError("error_handler must be a function");
            const params = info.@"fn".params;
            if (params.len != 4) @compileError("error_handler must be fn(*Server, *Io.Writer, comptime ErrorSet: type, err: ErrorSet) router.Action");
            if (params[0].type != *Self and params[0].type != null) @compileError("error_handler first param must be *Server");
            if (params[1].type != *Io.Writer and params[1].type != null) @compileError("error_handler second param must be *Io.Writer");
            if (params[2].type != type and params[2].type != null) @compileError("error_handler third param must be comptime ErrorSet: type");
            if (info.@"fn".return_type != Action) @compileError("error_handler must return router.Action");
        }

        fn callErrorHandler(self: *Self, w: *Io.Writer, comptime ErrorSet: type, err: ErrorSet) Action {
            comptime validateErrorHandler();
            return @call(.auto, ErrorHandler, .{ self, w, ErrorSet, err });
        }

        pub fn handleHandlerError(self: *Self, w: *Io.Writer, comptime ErrorSet: type, err: ErrorSet) Action {
            return self.callErrorHandler(w, ErrorSet, err);
        }

        inline fn handleDispatchServerError(self: *Self, w: *Io.Writer, err: anytype) Action {
            return switch (err) {
                error.EndOfStream, error.ReadFailed, error.WriteFailed => .close,
                error.HeadersTooLarge => blk2: {
                    self.writeSimple(w, 431, "bad request");
                    break :blk2 .close;
                },
                error.PayloadTooLarge => blk2: {
                    self.writeSimple(w, 413, "bad request");
                    break :blk2 .close;
                },
                error.MissingRequired,
                error.BadValue,
                error.InvalidPercentEncoding,
                error.BadRequest,
                error.StreamTooLong,
                => blk2: {
                    self.writeSimple(w, 400, "bad request");
                    break :blk2 .close;
                },
                error.OutOfMemory => blk2: {
                    self.writeSimple(w, 500, "internal error");
                    break :blk2 .close;
                },
            };
        }

        fn handleConn(self: *Self, state: *WorkerState, stream: std.Io.net.Stream) Io.Cancelable!void {
            if (Conf.tcp_nodelay) setTcpNoDelay(&stream);

            var close_stream = true;
            defer if (close_stream) self.closeStream(&stream);

            var sr = stream.reader(self.io, &state.read_buf);
            var sw = stream.writer(self.io, &state.write_buf);
            blk: switch (Action.@"continue") {
                .@"continue" => {
                    const a = state.allocator();
                    defer state.reset();

                    const action: Action = act: {
                        const line = request.parseRequestLineBorrowed(&sr.interface, Conf.max_request_line) catch |err| {
                            break :act switch (err) {
                                error.EndOfStream, error.ReadFailed => .close,
                                error.UriTooLong => blk2: {
                                    self.writeSimple(&sw.interface, 414, "bad request");
                                    break :blk2 .close;
                                },
                                error.BadRequest => blk2: {
                                    self.writeSimple(&sw.interface, 400, "bad request");
                                    break :blk2 .close;
                                },
                                error.OutOfMemory => blk2: {
                                    self.writeSimple(&sw.interface, 500, "internal error");
                                    break :blk2 .close;
                                },
                            };
                        };

                        break :act if (Compiled.match(line.method, line.path)) |idx| switch (idx) {
                            inline 0...(Compiled.RouteCount - 1) => |c_idx| routeAction(c_idx)(self, state, &sr.interface, &sw.interface, &stream, line, a) catch |err| self.handleDispatchServerError(&sw.interface, err),
                            else => unreachable,
                        } else notFoundAction()(self, state, &sr.interface, &sw.interface, &stream, line, a) catch |err| self.handleDispatchServerError(&sw.interface, err);
                    };

                    if (action == .upgraded) {
                        close_stream = false;
                        return;
                    }
                    sw.interface.flush() catch return;
                    continue :blk action;
                },
                .close => {
                    return;
                },
                .upgraded => {
                    close_stream = false;
                    return;
                },
            }
        }

        fn routeAction(comptime route_index: u16) RouteFn {
            return struct {
                fn call(
                    server: *Self,
                    state: *WorkerState,
                    r: *Io.Reader,
                    w: *Io.Writer,
                    stream: *const std.Io.net.Stream,
                    line: request.RequestLine,
                    a: Allocator,
                ) Compiled.DispatchError!Action {
                    _ = state;
                    var params_buf: [Compiled.RouteParamCounts[route_index]][]u8 = undefined;
                    return Compiled.dispatch(
                        server,
                        a,
                        r,
                        w,
                        stream,
                        line,
                        route_index,
                        params_buf[0..Compiled.RouteParamCounts[route_index]],
                        Conf.max_header_bytes,
                        Conf.max_single_header_size,
                    );
                }
            }.call;
        }

        fn notFoundAction() NotFoundFn {
            return struct {
                fn call(
                    server: *Self,
                    state: *WorkerState,
                    r: *Io.Reader,
                    w: *Io.Writer,
                    stream: *const std.Io.net.Stream,
                    line: request.RequestLine,
                    a: Allocator,
                ) NotFoundCompiled.DispatchError!Action {
                    _ = state;
                    var params_buf: [NotFoundCompiled.RouteParamCounts[0]][]u8 = undefined;
                    return NotFoundCompiled.dispatch(
                        server,
                        a,
                        r,
                        w,
                        stream,
                        line,
                        0,
                        params_buf[0..NotFoundCompiled.RouteParamCounts[0]],
                        Conf.max_header_bytes,
                        Conf.max_single_header_size,
                    );
                }
            }.call;
        }
    };
}

fn primeSocketBackend() void {
    if (builtin.os.tag == .windows) return;

    // Work around a std.Io test-process quirk where the first high-level
    // loopback listen can fail unless the socket backend has been touched once.
    const posix = std.posix;
    const rc = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    if (posix.errno(rc) == .SUCCESS) {
        _ = posix.system.close(@intCast(rc));
    }
}

fn renderTextResponse(
    status: u16,
    body: []const u8,
    keep_alive: bool,
    send_body: bool,
    out: []u8,
) ![]const u8 {
    var w = Io.Writer.fixed(out);
    try response.write(&w, response.Res.text(status, body), keep_alive, send_body);
    return out[0..w.end];
}

fn renderUpgradeResponse(headers: []const response.Header, out: []u8) ![]const u8 {
    var w = Io.Writer.fixed(out);
    const res: response.Res = .{
        .status = .switching_protocols,
        .headers = headers,
    };
    try response.writeUpgrade(&w, res);
    return out[0..w.end];
}

fn expectReadEquals(r: *Io.Reader, expected: []const u8) !void {
    var got_buf: [8192]u8 = undefined;
    std.debug.assert(expected.len <= got_buf.len);
    try r.readSliceAll(got_buf[0..expected.len]);
    try std.testing.expectEqualStrings(expected, got_buf[0..expected.len]);
}

fn expectClosed(r: *Io.Reader) !void {
    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, r.readSliceAll(one[0..]));
}

fn trimCR(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn trimHeaderValue(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) b -= 1;
    return s[a..b];
}

fn performWebSocketHandshake(sr: *Io.Reader, sw: *Io.Writer, path: []const u8) !void {
    var req_buf: [1024]u8 = undefined;
    const req = try std.fmt.bufPrint(
        &req_buf,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
        .{path},
    );
    try sw.writeAll(req);
    try sw.flush();

    const status_line_incl = try sr.takeDelimiterInclusive('\n');
    const status_line = trimCR(status_line_incl[0 .. status_line_incl.len - 1]);
    try std.testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols", status_line);

    var saw_accept = false;
    while (true) {
        const line_incl = try sr.takeDelimiterInclusive('\n');
        const line = trimCR(line_incl[0 .. line_incl.len - 1]);
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHandshake;
        const name = line[0..colon];
        const value = trimHeaderValue(line[colon + 1 ..]);
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            const expected = try zws.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==");
            try std.testing.expectEqualStrings(expected[0..], value);
            saw_accept = true;
        }
    }
    try std.testing.expect(saw_accept);
}

fn appendClientFrame(
    buf: []u8,
    opcode: u8,
    payload: []const u8,
    fin: bool,
    masked: bool,
    rsv1: bool,
) ![]const u8 {
    var w = Io.Writer.fixed(buf);
    var b0: u8 = opcode;
    if (fin) b0 |= 0x80;
    if (rsv1) b0 |= 0x40;
    try w.writeByte(b0);

    if (payload.len < 126) {
        try w.writeByte((if (masked) @as(u8, 0x80) else 0) | @as(u8, @intCast(payload.len)));
    } else {
        try w.writeByte((if (masked) @as(u8, 0x80) else 0) | 126);
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, len_buf[0..], @intCast(payload.len), .big);
        try w.writeAll(len_buf[0..]);
    }

    const mask = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    if (masked) {
        try w.writeAll(mask[0..]);
        var masked_payload: [512]u8 = undefined;
        if (payload.len > masked_payload.len) return error.BufferTooSmall;
        for (payload, 0..) |b, i| masked_payload[i] = b ^ mask[i % mask.len];
        try w.writeAll(masked_payload[0..payload.len]);
    } else {
        try w.writeAll(payload);
    }

    return buf[0..w.end];
}

fn sendOneShotExpect(io: Io, port: u16, req: []const u8, expected: []const u8) !void {
    var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [8 * 1024]u8 = undefined;
    var wb: [2 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll(req);
    try sw.interface.flush();
    try expectReadEquals(&sr.interface, expected);
    try expectClosed(&sr.interface);
}

fn sendAndCloseEarly(io: Io, port: u16, req_prefix: []const u8) !void {
    var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
    defer stream.close(io);

    var wb: [2 * 1024]u8 = undefined;
    var sw = stream.writer(io, &wb);
    try sw.interface.writeAll(req_prefix);
    try sw.interface.flush();
}

fn stopServerTest(io: Io, group: *Io.Group, server: anytype) void {
    server.stop();
    group.await(io) catch {};
    server.deinit();
}

fn randomAscii(random: std.Random, buf: []u8) void {
    for (buf) |*b| b.* = 'a' + random.uintLessThan(u8, 26);
}

fn appendChunkedBody(buf: []u8, body: []const u8, random: std.Random) ![]const u8 {
    var w = Io.Writer.fixed(buf);
    var start: usize = 0;
    while (start < body.len) {
        const remaining = body.len - start;
        const chunk_len = 1 + random.uintLessThan(usize, remaining);
        var len_buf: [16]u8 = undefined;
        const len_hex = try std.fmt.bufPrint(&len_buf, "{x}", .{chunk_len});
        try w.writeAll(len_hex);
        try w.writeAll("\r\n");
        try w.writeAll(body[start .. start + chunk_len]);
        try w.writeAll("\r\n");
        start += chunk_len;
    }
    try w.writeAll("0\r\n\r\n");
    return buf[0..w.end];
}

fn runSoakVarietyCase(
    io: Io,
    port: u16,
    random: std.Random,
    case_id: usize,
    upgrade_cases: *usize,
    malformed_cases: *usize,
    keepalive_cases: *usize,
) !void {
    switch (case_id) {
        0 => {
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(200, "ok", false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, "GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", expected);
        },
        1 => {
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(200, "ok", false, false, expected_buf[0..]);
            try sendOneShotExpect(io, port, "HEAD /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", expected);
        },
        2 => {
            var body: [32]u8 = undefined;
            const len = random.uintLessThan(usize, body.len + 1);
            randomAscii(random, body[0..len]);

            var req_buf: [512]u8 = undefined;
            const req = try std.fmt.bufPrint(
                &req_buf,
                "POST /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ len, body[0..len] },
            );
            var resp_body: [64]u8 = undefined;
            const body_out = try std.fmt.bufPrint(&resp_body, "echo:{s}", .{body[0..len]});
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(200, body_out, false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, req, expected);
        },
        3 => {
            var body: [32]u8 = undefined;
            const len = random.uintLessThan(usize, body.len + 1);
            randomAscii(random, body[0..len]);
            var chunk_buf: [512]u8 = undefined;
            const chunks = try appendChunkedBody(chunk_buf[0..], body[0..len], random);

            var req_buf: [768]u8 = undefined;
            const req = try std.fmt.bufPrint(
                &req_buf,
                "POST /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n{s}",
                .{chunks},
            );
            var resp_body: [64]u8 = undefined;
            const body_out = try std.fmt.bufPrint(&resp_body, "echo:{s}", .{body[0..len]});
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(200, body_out, false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, req, expected);
        },
        4 => {
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(200, "123", false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, "GET /item/123 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", expected);
        },
        5 => {
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(200, "123", false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, "GET /item/%31%32%33 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", expected);
        },
        6 => {
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(200, "a b", false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, "GET /search?name=a%20b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", expected);
        },
        7 => {
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(404, "not found", false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, "GET /missing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", expected);
        },
        8 => {
            malformed_cases.* += 1;
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(400, "bad request", false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, "POST /drain HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n", expected);
        },
        9 => {
            malformed_cases.* += 1;
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(400, "bad request", false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, "POST /drain HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n", expected);
        },
        10 => {
            malformed_cases.* += 1;
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(400, "bad request", false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, "GET /ok HTTP/1.1\r\nBroken\r\n\r\n", expected);
        },
        11 => {
            malformed_cases.* += 1;
            var req_buf: [512]u8 = undefined;
            var w = Io.Writer.fixed(req_buf[0..]);
            try w.writeAll("GET /ok HTTP/1.1\r\nX: ");
            var i: usize = 0;
            while (i < 300) : (i += 1) try w.writeByte('z');
            try w.writeAll("\r\n\r\n");
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(431, "bad request", false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, req_buf[0..w.end], expected);
        },
        12 => {
            upgrade_cases.* += 1;
            var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
            defer stream.close(io);

            var rb: [4 * 1024]u8 = undefined;
            var wb: [512]u8 = undefined;
            var sr = stream.reader(io, &rb);
            var sw = stream.writer(io, &wb);

            try sw.interface.writeAll(
                "GET /up HTTP/1.1\r\n" ++
                    "Host: x\r\n" ++
                    "Connection: Upgrade\r\n" ++
                    "Upgrade: testproto\r\n" ++
                    "\r\n",
            );
            try sw.interface.flush();

            var expected_buf: [256]u8 = undefined;
            const expected = try renderUpgradeResponse(&.{
                .{ .name = "connection", .value = "Upgrade" },
                .{ .name = "upgrade", .value = "testproto" },
            }, expected_buf[0..]);
            try expectReadEquals(&sr.interface, expected);
            try sw.interface.writeAll("ping");
            try sw.interface.flush();
            try expectReadEquals(&sr.interface, "pong");
            try expectClosed(&sr.interface);
        },
        13 => {
            keepalive_cases.* += 1;
            var body: [24]u8 = undefined;
            const len = 1 + random.uintLessThan(usize, body.len);
            randomAscii(random, body[0..len]);

            var req_buf: [768]u8 = undefined;
            const req = try std.fmt.bufPrint(
                &req_buf,
                "POST /drain HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n{s}" ++
                    "GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
                .{ len, body[0..len] },
            );

            var resp1_buf: [256]u8 = undefined;
            const resp1 = try renderTextResponse(200, "drain", true, true, resp1_buf[0..]);
            var resp2_buf: [256]u8 = undefined;
            const resp2 = try renderTextResponse(200, "ok", false, true, resp2_buf[0..]);
            var expected_concat: [512]u8 = undefined;
            @memcpy(expected_concat[0..resp1.len], resp1);
            @memcpy(expected_concat[resp1.len .. resp1.len + resp2.len], resp2);
            try sendOneShotExpect(io, port, req, expected_concat[0 .. resp1.len + resp2.len]);
        },
        14 => {
            malformed_cases.* += 1;
            var expected_buf: [256]u8 = undefined;
            const expected = try renderTextResponse(400, "bad request", false, true, expected_buf[0..]);
            try sendOneShotExpect(io, port, "POST /drain HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\r\naXY0\r\n\r\n", expected);
        },
        15 => {
            malformed_cases.* += 1;
            try sendAndCloseEarly(io, port, "GET /ok HTTP/1.1\r\nHost: x");
        },
        16 => {
            malformed_cases.* += 1;
            try sendAndCloseEarly(io, port, "POST /drain HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\nabc");
        },
        17 => {
            upgrade_cases.* += 1;
            var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
            defer stream.close(io);

            var rb: [4 * 1024]u8 = undefined;
            var wb: [512]u8 = undefined;
            var sr = stream.reader(io, &rb);
            var sw = stream.writer(io, &wb);

            try sw.interface.writeAll(
                "GET /up HTTP/1.1\r\n" ++
                    "Host: x\r\n" ++
                    "Connection: Upgrade\r\n" ++
                    "Upgrade: testproto\r\n" ++
                    "\r\n",
            );
            try sw.interface.flush();

            var expected_buf: [256]u8 = undefined;
            const expected = try renderUpgradeResponse(&.{
                .{ .name = "connection", .value = "Upgrade" },
                .{ .name = "upgrade", .value = "testproto" },
            }, expected_buf[0..]);
            try expectReadEquals(&sr.interface, expected);
            try stream.shutdown(io, .send);
            try expectClosed(&sr.interface);
        },
        else => unreachable,
    }
}

test "Server config: arena_reset_limit override is applied" {
    const SrvT = Server(.{
        .routes = .{
            router.get("/", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return response.Res.text(200, "ok");
                }
            }),
        },
        .config = .{
            .arena_reset_limit = 12345,
        },
    });
    try std.testing.expectEqual(@as(usize, 12345), SrvT.config.arena_reset_limit);
}

test "Server config: listener_shards=1 compiles listener selection path" {
    const SrvT = Server(.{
        .routes = .{
            router.get("/", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return response.Res.text(200, "ok");
                }
            }),
        },
        .config = .{
            .listener_shards = 1,
        },
    });
    const listener_at: fn (*SrvT, usize) *std.Io.net.Server = SrvT.listenerAt;
    _ = listener_at;
}

test "Server stop: stop after deinit is a no-op" {
    primeSocketBackend();
    const io = std.testing.io;

    const SrvT = Server(.{
        .routes = .{
            router.get("/", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return response.Res.text(200, "ok");
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    server.deinit();
    server.stop();
}

test "Server stop: blocked accept loop shuts down cleanly" {
    primeSocketBackend();
    const io = std.testing.io;

    const SrvT = Server(.{
        .routes = .{
            router.get("/", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return response.Res.text(200, "ok");
                }
            }),
        },
    });

    for (0..64) |_| {
        const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
        var group: Io.Group = .init;
        var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
        const port: u16 = server.listener.socket.address.getPort();
        try std.testing.expect(port != 0);

        try group.concurrent(io, SrvT.serve, .{ &server, .{} });

        // Drive one full request so the accept loop returns to its steady-state
        // blocking-accept path before shutdown, without leaving a connection
        // task mid-read.
        var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });

        var rb: [1024]u8 = undefined;
        var wb: [256]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);
        try sw.interface.writeAll("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        try sw.interface.flush();

        const resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: close\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 2\r\n" ++
            "\r\n" ++
            "ok";
        var got: [resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(resp, got[0..]);
        try expectClosed(&sr.interface);
        stream.close(io);

        stopServerTest(io, &group, &server);
    }
}

test "Server stop: idle keepalive peer-close then shutdown is clean" {
    primeSocketBackend();
    const io = std.testing.io;

    const SrvT = Server(.{
        .routes = .{
            router.get("/", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return response.Res.text(200, "ok");
                }
            }),
        },
    });

    for (0..16) |_| {
        const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
        var group: Io.Group = .init;
        var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
        const port: u16 = server.listener.socket.address.getPort();
        try group.concurrent(io, SrvT.serve, .{ &server, .{} });

        var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });

        var rb: [1024]u8 = undefined;
        var wb: [256]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);
        try sw.interface.writeAll("GET / HTTP/1.1\r\nHost: x\r\n\r\n");
        try sw.interface.flush();

        const resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: keep-alive\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 2\r\n" ++
            "\r\n" ++
            "ok";
        var got: [resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(resp, got[0..]);

        stream.close(io);
        stopServerTest(io, &group, &server);
    }
}

test "Server stop: concurrent stop calls are race-free and idempotent" {
    primeSocketBackend();
    const io = std.testing.io;

    const SrvT = Server(.{
        .routes = .{
            router.get("/", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return response.Res.text(200, "ok");
                }
            }),
        },
    });

    const StopCtx = struct {
        server: *SrvT,

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < 64) : (i += 1) self.server.stop();
        }
    };

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    var stop_ctx = StopCtx{ .server = &server };
    const t1 = try std.Thread.spawn(.{}, StopCtx.run, .{&stop_ctx});
    const t2 = try std.Thread.spawn(.{}, StopCtx.run, .{&stop_ctx});
    t1.join();
    t2.join();

    stopServerTest(io, &group, &server);
}

test "Connection: close header closes socket" {
    const Bench = struct {
        fn plaintext(_: anytype) !response.Res {
            return .{
                .status = .ok,
                .headers = &.{
                    .{ .name = "Server", .value = "F" },
                    .{ .name = "Content-Type", .value = "text/plain" },
                    .{ .name = "Date", .value = "Wed, 24 Feb 2021 12:00:00 GMT" },
                },
                .body = "Hello, World!",
            };
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/plaintext", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Bench.plaintext(req);
                }
            }),
        },
        .config = .{
            .read_buffer = 64 * 1024,
            .write_buffer = 16 * 1024,
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);

    const port: u16 = server.listener.socket.address.getPort();
    try std.testing.expect(port != 0);

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    const req =
        "GET /plaintext HTTP/1.1\r\n" ++
        "Host: 127.0.0.1\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "Server: F\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Date: Wed, 24 Feb 2021 12:00:00 GMT\r\n" ++
        "content-length: 13\r\n" ++
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
}

test "unknown path returns 404 and keeps connection" {
    const Handlers = struct {
        fn ok(_: anytype) !response.Res {
            return response.Res.text(200, "ok");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Handlers.ok(req);
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GET /nope HTTP/1.1\r\nHost: x\r\n\r\n");
    try sw.interface.flush();

    const not_found_resp =
        "HTTP/1.1 404 Not Found\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 9\r\n" ++
        "\r\n" ++
        "not found";
    var got_nf: [not_found_resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got_nf[0..]);
    try std.testing.expectEqualStrings(not_found_resp, got_nf[0..]);

    try sw.interface.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try sw.interface.flush();

    const ok_resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 2\r\n" ++
        "\r\n" ++
        "ok";
    var got_ok: [ok_resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got_ok[0..]);
    try std.testing.expectEqualStrings(ok_resp, got_ok[0..]);
    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));
}

test "not_found_handler can parse query headers and body" {
    const Handlers = struct {
        fn ok(_: anytype) !response.Res {
            return response.Res.text(200, "ok");
        }

        fn missing(req: anytype) !response.Res {
            const name = req.queryParam(.name) orelse "world";
            const host = req.header(.host) orelse "(no host)";
            const body = try req.bodyAll(1024);
            const out = try std.fmt.allocPrint(req.allocator(), "miss {s} {s} {s}", .{ name, host, body });
            return response.Res.text(200, out);
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Handlers.ok(req);
                }
            }),
        },
        .not_found_handler = struct {
            pub const Info: router.EndpointInfo = .{
                .query = struct {
                    name: parse.Optional(parse.String),
                },
                .headers = struct {
                    host: parse.Optional(parse.String),
                },
            };
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                return Handlers.missing(req);
            }
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [512]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    const req =
        "POST /missing?name=zig HTTP/1.1\r\n" ++
        "Host: example\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello";
    try sw.interface.writeAll(req);
    try sw.interface.flush();

    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 22\r\n" ++
        "\r\n" ++
        "miss zig example hello";
    var got: [resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(resp, got[0..]);

    try sw.interface.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try sw.interface.flush();

    const ok_resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 2\r\n" ++
        "\r\n" ++
        "ok";
    var got_ok: [ok_resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got_ok[0..]);
    try std.testing.expectEqualStrings(ok_resp, got_ok[0..]);
    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));
}

test "HEAD response omits body" {
    const Handlers = struct {
        fn ok(_: anytype) !response.Res {
            return response.Res.text(200, "hello");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Handlers.ok(req);
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("HEAD /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try sw.interface.flush();

    const head_resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 5\r\n" ++
        "\r\n";
    var got: [head_resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(head_resp, got[0..]);

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));
}

test "bad request line returns 400" {
    const Handlers = struct {
        fn ok(_: anytype) !response.Res {
            return response.Res.text(200, "ok");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Handlers.ok(req);
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GARBAGE\r\n\r\n");
    try sw.interface.flush();

    const bad_resp =
        "HTTP/1.1 400 Bad Request\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 11\r\n" ++
        "\r\n" ++
        "bad request";
    var got: [bad_resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(bad_resp, got[0..]);

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));
}

test "custom error_handler handles handler errors only" {
    const Handlers = struct {
        fn boom(_: anytype) !response.Res {
            return error.Boom;
        }

        fn onError(_: anytype, w: *Io.Writer, comptime ErrorSet: type, _: ErrorSet) router.Action {
            const body = "custom boom";
            response.write(w, response.Res.text(499, body), false, true) catch unreachable;
            // Deliberately do not flush here; router dispatch must flush handler-error writes.
            return .close;
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/boom", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Handlers.boom(req);
                }
            }),
        },
        .error_handler = Handlers.onError,
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };

    {
        var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [256]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        try sw.interface.writeAll("GARBAGE\r\n\r\n");
        try sw.interface.flush();

        const resp =
            "HTTP/1.1 400 Bad Request\r\n" ++
            "connection: close\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 11\r\n" ++
            "\r\n" ++
            "bad request";
        var got: [resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(resp, got[0..]);
    }

    {
        var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [256]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        try sw.interface.writeAll("GET /boom HTTP/1.1\r\nHost: x\r\n\r\n");
        try sw.interface.flush();

        const resp =
            "HTTP/1.1 499\r\n" ++
            "connection: close\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 11\r\n" ++
            "\r\n" ++
            "custom boom";
        var got: [resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got[0..]);
        try std.testing.expectEqualStrings(resp, got[0..]);
    }
}

test "handler res.close closes socket" {
    const Handlers = struct {
        fn close_me(_: anytype) !response.Res {
            var r = response.Res.text(200, "bye");
            r.close = true;
            return r;
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/x", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Handlers.close_me(req);
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GET /x HTTP/1.1\r\nHost: x\r\n\r\n");
    try sw.interface.flush();

    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 3\r\n" ++
        "\r\n" ++
        "bye";
    var got: [resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(resp, got[0..]);

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));
}

test "HTTP/1.0 request does not keep-alive" {
    const Handlers = struct {
        fn ok() !response.Res {
            return response.Res.text(200, "ok");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/x", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return Handlers.ok();
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GET /x HTTP/1.0\r\n\r\n");
    try sw.interface.flush();

    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 2\r\n" ++
        "\r\n" ++
        "ok";
    var got: [resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(resp, got[0..]);

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));
}

test "endpoint upgrade: 101 triggers upgrade callback and stream ownership" {
    const State = struct {
        upgraded: bool = false,
    };

    const Handlers = struct {
        fn ws(_: anytype) !response.Res {
            return .{
                .status = .switching_protocols,
                .headers = &.{
                    .{ .name = "connection", .value = "Upgrade" },
                    .{ .name = "upgrade", .value = "websocket" },
                },
            };
        }

        fn onUpgrade(server: anytype, stream: *const std.Io.net.Stream, _: *Io.Reader, _: *Io.Writer, _: request.RequestLine, _: response.Res) void {
            server.ctx.upgraded = true;
            stream.close(server.io);
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    var state: State = .{};
    const SrvT = Server(.{
        .Context = State,
        .routes = .{
            router.get("/ws", struct {
                pub const Info: router.EndpointInfo = .{};
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Handlers.ws(req);
                }

                pub fn upgrade(server: anytype, stream: *const std.Io.net.Stream, r: *Io.Reader, w: *Io.Writer, line: request.RequestLine, res: response.Res) void {
                    return Handlers.onUpgrade(server, stream, r, w, line, res);
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, &state);
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll(
        "GET /ws HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "\r\n",
    );
    try sw.interface.flush();

    const expected =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "connection: Upgrade\r\n" ++
        "upgrade: websocket\r\n" ++
        "\r\n";
    var got: [expected.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(expected, got[0..]);

    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));
    try std.testing.expect(state.upgraded);
}

test "middleware static_context: per-route init and request access" {
    const RouteStaticCtx = struct {
        pattern: []const u8,
        method: []const u8,

        pub fn init(_: Io, _: Allocator, route_decl: router.RouteDecl) @This() {
            return .{
                .pattern = route_decl.pattern,
                .method = route_decl.method,
            };
        }
    };

    const StaticMw = struct {
        pub const Info: middleware.MiddlewareInfo = .{
            .name = "static_ctx",
            .static_context = RouteStaticCtx,
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
            return rctx.next(req);
        }
    };

    const Handlers = struct {
        fn a(req: anytype) !response.Res {
            const sc = req.middlewareStaticConst(.static_ctx);
            return response.Res.text(200, sc.pattern);
        }

        fn b(req: anytype) !response.Res {
            const sc = req.middlewareStaticConst(.static_ctx);
            const out = try std.fmt.allocPrint(req.allocator(), "{s}:{s}", .{ sc.method, sc.pattern });
            return response.Res.text(200, out);
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/a", struct {
                pub const Info: router.EndpointInfo = .{
                    .middlewares = &.{StaticMw},
                };
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Handlers.a(req);
                }
            }),
            router.get("/b", struct {
                pub const Info: router.EndpointInfo = .{
                    .middlewares = &.{StaticMw},
                };
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Handlers.b(req);
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };
    var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GET /a HTTP/1.1\r\nHost: x\r\n\r\n");
    try sw.interface.flush();

    const resp_a =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 2\r\n" ++
        "\r\n" ++
        "/a";
    var got_a: [resp_a.len]u8 = undefined;
    try sr.interface.readSliceAll(got_a[0..]);
    try std.testing.expectEqualStrings(resp_a, got_a[0..]);

    try sw.interface.writeAll("GET /b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try sw.interface.flush();

    const resp_b =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 6\r\n" ++
        "\r\n" ++
        "GET:/b";
    var got_b: [resp_b.len]u8 = undefined;
    try sr.interface.readSliceAll(got_b[0..]);
    try std.testing.expectEqualStrings(resp_b, got_b[0..]);
    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));
}

test "middleware static_context: init errors propagate from Server.init" {
    const FailingStaticCtx = struct {
        pub fn init(_: Io, _: Allocator, _: router.RouteDecl) !@This() {
            return error.StaticContextInitFailed;
        }
    };

    const FailingMw = struct {
        pub const Info: middleware.MiddlewareInfo = .{
            .name = "failing_static",
            .static_context = FailingStaticCtx,
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
            return rctx.next(req);
        }
    };

    const Handlers = struct {
        fn ok(_: anytype) !response.Res {
            return response.Res.text(200, "ok");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/x", struct {
                pub const Info: router.EndpointInfo = .{
                    .middlewares = &.{FailingMw},
                };
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    return Handlers.ok(req);
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    try std.testing.expectError(error.StaticContextInitFailed, SrvT.initOwned(std.testing.allocator, io, addr0, {}));
}

test "middleware static_context: deinit runs once per route" {
    const RouteStaticCtx = struct {
        pattern: []const u8 = "",
        deinit_count: usize = 0,

        pub fn init(_: Io, _: Allocator, route_decl: router.RouteDecl) @This() {
            return .{ .pattern = route_decl.pattern };
        }

        pub fn deinit(self: *@This(), _: Io, _: Allocator) void {
            self.deinit_count += 1;
            self.pattern = "";
        }
    };

    const StaticMw = struct {
        pub const Info: middleware.MiddlewareInfo = .{
            .name = "route_static",
            .static_context = RouteStaticCtx,
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
            return rctx.next(req);
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/a", struct {
                pub const Info: router.EndpointInfo = .{
                    .middlewares = &.{StaticMw},
                };
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return response.Res.text(200, "ok");
                }
            }),
            router.get("/b", struct {
                pub const Info: router.EndpointInfo = .{
                    .middlewares = &.{StaticMw},
                };
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return response.Res.text(200, "ok");
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});

    try std.testing.expectEqualStrings("/a", server.routeStatic(0).route_static.pattern);
    try std.testing.expectEqualStrings("/b", server.routeStatic(1).route_static.pattern);
    try std.testing.expectEqual(@as(usize, 0), server.routeStatic(0).route_static.deinit_count);
    try std.testing.expectEqual(@as(usize, 0), server.routeStatic(1).route_static.deinit_count);

    server.deinit();

    try std.testing.expectEqualStrings("", server.routeStatic(0).route_static.pattern);
    try std.testing.expectEqualStrings("", server.routeStatic(1).route_static.pattern);
    try std.testing.expectEqual(@as(usize, 1), server.routeStatic(0).route_static.deinit_count);
    try std.testing.expectEqual(@as(usize, 1), server.routeStatic(1).route_static.deinit_count);

    // Deinit is idempotent.
    server.deinit();
    try std.testing.expectEqual(@as(usize, 1), server.routeStatic(0).route_static.deinit_count);
    try std.testing.expectEqual(@as(usize, 1), server.routeStatic(1).route_static.deinit_count);
}

test "middleware static_context: partial init failure cleans up previously initialized routes" {
    const StaticCtx = struct {
        buf: []u8 = &.{},

        pub fn init(_: Io, allocator: Allocator, route_decl: router.RouteDecl) !@This() {
            if (std.mem.eql(u8, route_decl.pattern, "/fail")) return error.StaticContextInitFailed;
            return .{ .buf = try allocator.dupe(u8, route_decl.pattern) };
        }

        pub fn deinit(self: *@This(), _: Io, allocator: Allocator) void {
            if (self.buf.len != 0) allocator.free(self.buf);
            self.buf = &.{};
        }
    };

    const StaticMw = struct {
        pub const Info: middleware.MiddlewareInfo = .{
            .name = "route_static",
            .static_context = StaticCtx,
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
            return rctx.next(req);
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", struct {
                pub const Info: router.EndpointInfo = .{
                    .middlewares = &.{StaticMw},
                };
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return response.Res.text(200, "ok");
                }
            }),
            router.get("/fail", struct {
                pub const Info: router.EndpointInfo = .{
                    .middlewares = &.{StaticMw},
                };
                pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                    _ = req;
                    return response.Res.text(200, "ok");
                }
            }),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    try std.testing.expectError(error.StaticContextInitFailed, SrvT.initOwned(std.testing.allocator, io, addr0, {}));
}

test "ReqCtx.Server allows cross-route static context access" {
    const RouteStaticCtx = struct {
        pattern: []const u8,
        touched: usize = 0,

        pub fn init(_: Io, _: Allocator, route_decl: router.RouteDecl) @This() {
            return .{
                .pattern = route_decl.pattern,
            };
        }
    };

    const StaticMw = struct {
        pub const Info: middleware.MiddlewareInfo = .{
            .name = "route_static",
            .static_context = RouteStaticCtx,
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
            return rctx.next(req);
        }
    };

    const Touch = struct {
        pub const Info: router.EndpointInfo = .{
            .middlewares = &.{StaticMw},
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
            const ServerT = rctx.Server();
            comptime {
                _ = ServerT.RouteCount;
                _ = ServerT.RouteDeclList;
                _ = ServerT.RouteStaticType(ServerT.routeIndex("GET", "/state"));
            }
            const decls = req.server().routeDecls();
            if (decls.len != 2) return response.Res.text(500, "bad route list");
            const state_idx = comptime ServerT.routeIndex("GET", "/state");
            const state_static = req.server().routeStatic(state_idx);
            state_static.route_static.touched += 1;
            _ = req.server().routeStaticTuple();
            return response.Res.text(200, "touched");
        }
    };

    const State = struct {
        pub const Info: router.EndpointInfo = .{
            .middlewares = &.{StaticMw},
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
            const me = req.middlewareStaticConst(.route_static);
            const ServerT = @TypeOf(req.server().*);
            const me2 = req.server().routeStaticConst(comptime ServerT.routeIndex("GET", "/state"));
            const body = try std.fmt.allocPrint(req.allocator(), "{s}:{d}", .{ me.pattern, me2.route_static.touched });
            return response.Res.text(200, body);
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/touch", Touch),
            router.get("/state", State),
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [256]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GET /state HTTP/1.1\r\nHost: x\r\n\r\n");
    try sw.interface.flush();
    const state0 =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 8\r\n" ++
        "\r\n" ++
        "/state:0";
    var got0: [state0.len]u8 = undefined;
    try sr.interface.readSliceAll(got0[0..]);
    try std.testing.expectEqualStrings(state0, got0[0..]);

    try sw.interface.writeAll("GET /touch HTTP/1.1\r\nHost: x\r\n\r\n");
    try sw.interface.flush();
    const touched =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: keep-alive\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 7\r\n" ++
        "\r\n" ++
        "touched";
    var got1: [touched.len]u8 = undefined;
    try sr.interface.readSliceAll(got1[0..]);
    try std.testing.expectEqualStrings(touched, got1[0..]);

    try sw.interface.writeAll("GET /state HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try sw.interface.flush();
    const state1 =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 8\r\n" ++
        "\r\n" ++
        "/state:1";
    var got2: [state1.len]u8 = undefined;
    try sr.interface.readSliceAll(got2[0..]);
    try std.testing.expectEqualStrings(state1, got2[0..]);
    var one: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, sr.interface.readSliceAll(one[0..]));
}

test "server variation: global middleware applies to route and not_found handler" {
    const HeaderMw = struct {
        pub const Info: middleware.MiddlewareInfo = .{
            .name = "hdr",
        };

        pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
            var res = try rctx.next(req);
            const a = req.allocator();
            const out = try a.alloc(response.Header, res.headers.len + 1);
            @memcpy(out[0..res.headers.len], res.headers);
            out[res.headers.len] = .{ .name = "x-global-mw", .value = "1" };
            res.headers = out;
            return res;
        }
    };

    const OkEndpoint = struct {
        pub const Info: router.EndpointInfo = .{};
        pub fn call(comptime _: ReqCtx, _: anytype) !response.Res {
            return response.Res.text(200, "ok");
        }
    };

    const NotFoundEndpoint = struct {
        pub const Info: router.EndpointInfo = .{};
        pub fn call(comptime _: ReqCtx, _: anytype) !response.Res {
            return response.Res.text(404, "miss");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .middlewares = .{HeaderMw},
        .routes = .{
            router.get("/ok", OkEndpoint),
        },
        .not_found_handler = NotFoundEndpoint,
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    const addr: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(port) };

    {
        var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [256]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        try sw.interface.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        try sw.interface.flush();

        const ok_resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: close\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "x-global-mw: 1\r\n" ++
            "content-length: 2\r\n" ++
            "\r\n" ++
            "ok";
        var got_ok: [ok_resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got_ok[0..]);
        try std.testing.expectEqualStrings(ok_resp, got_ok[0..]);
    }

    {
        var stream = try Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [256]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        try sw.interface.writeAll("GET /missing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        try sw.interface.flush();

        const miss_resp =
            "HTTP/1.1 404 Not Found\r\n" ++
            "connection: close\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "x-global-mw: 1\r\n" ++
            "content-length: 4\r\n" ++
            "\r\n" ++
            "miss";
        var got_miss: [miss_resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got_miss[0..]);
        try std.testing.expectEqualStrings(miss_resp, got_miss[0..]);
    }
}

test "server variation: operations.Cors generates runtime OPTIONS preflight route" {
    const CorsMw = middleware.Cors(.{
        .origins = &.{"https://allowed.test"},
        .methods = &.{"GET"},
    });

    const ApiEndpoint = struct {
        pub const Info: router.EndpointInfo = .{
            .middlewares = &.{CorsMw},
            .operations = &.{operations.Cors},
        };
        pub fn call(comptime _: ReqCtx, _: anytype) !response.Res {
            return response.Res.text(200, "ok");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/api", ApiEndpoint),
        },
        .operations = .{operations.Cors},
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [512]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll(
        "OPTIONS /api HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Origin: https://allowed.test\r\n" ++
            "Access-Control-Request-Method: GET\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
    );
    try sw.interface.flush();

    const resp =
        "HTTP/1.1 204 No Content\r\n" ++
        "connection: close\r\n" ++
        "access-control-allow-origin: https://allowed.test\r\n" ++
        "access-control-allow-methods: GET\r\n" ++
        "vary: origin, access-control-request-method, access-control-request-headers\r\n" ++
        "content-length: 0\r\n" ++
        "\r\n";
    var got: [resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(resp, got[0..]);
    try expectClosed(&sr.interface);
}

test "server variation: operations.Static generates runtime GET and HEAD mount routes" {
    const StaticMw = middleware.Static(.{
        .dir = "testdata/static",
        .mount = "/assets",
        .etag = false,
        .in_memory_cache = false,
        .fs_watch = .{ .enabled = false },
    });

    const AnchorEndpoint = struct {
        pub const Info: router.EndpointInfo = .{
            .middlewares = &.{StaticMw},
            .operations = &.{operations.Static},
        };
        pub fn call(comptime _: ReqCtx, _: anytype) !response.Res {
            return response.Res.text(200, "anchor");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .middlewares = .{StaticMw},
        .routes = .{
            router.get("/_anchor", AnchorEndpoint),
        },
        .operations = .{operations.Static},
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    {
        var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [512]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        try sw.interface.writeAll("HEAD /assets/hello.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        try sw.interface.flush();

        const head_resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: close\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 6\r\n" ++
            "\r\n";
        var got_head: [head_resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got_head[0..]);
        try std.testing.expectEqualStrings(head_resp, got_head[0..]);
    }

    {
        var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [4 * 1024]u8 = undefined;
        var wb: [512]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);

        try sw.interface.writeAll("GET /assets/hello.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        try sw.interface.flush();

        const get_resp =
            "HTTP/1.1 200 OK\r\n" ++
            "connection: close\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 6\r\n" ++
            "\r\n" ++
            "hello\n";
        var got_get: [get_resp.len]u8 = undefined;
        try sr.interface.readSliceAll(got_get[0..]);
        try std.testing.expectEqualStrings(get_resp, got_get[0..]);
    }
}

test "server variation: unbuffered writer config works" {
    const SimpleEndpoint = struct {
        pub const Info: router.EndpointInfo = .{};
        pub fn call(comptime _: ReqCtx, _: anytype) !response.Res {
            return response.Res.text(200, "ok");
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", SimpleEndpoint),
        },
        .config = .{
            .read_buffer = 4 * 1024,
            .write_buffer = 0,
            .max_request_line = 1024,
            .max_single_header_size = 1024,
            .max_header_bytes = 4 * 1024,
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
    defer stream.close(io);

    var rb: [4 * 1024]u8 = undefined;
    var wb: [1]u8 = undefined;
    var sr = stream.reader(io, &rb);
    var sw = stream.writer(io, &wb);

    try sw.interface.writeAll("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try sw.interface.flush();

    const resp =
        "HTTP/1.1 200 OK\r\n" ++
        "connection: close\r\n" ++
        "content-type: text/plain; charset=utf-8\r\n" ++
        "content-length: 2\r\n" ++
        "\r\n" ++
        "ok";
    var got: [resp.len]u8 = undefined;
    try sr.interface.readSliceAll(got[0..]);
    try std.testing.expectEqualStrings(resp, got[0..]);
    try expectClosed(&sr.interface);
}

test "server adversarial malformed clients recover and keep serving" {
    const Endpoints = struct {
        const Ok = struct {
            pub const Info: router.EndpointInfo = .{};
            pub fn call(comptime _: ReqCtx, _: anytype) !response.Res {
                return response.Res.text(200, "ok");
            }
        };

        const Drain = struct {
            pub const Info: router.EndpointInfo = .{};
            pub fn call(comptime _: ReqCtx, _: anytype) !response.Res {
                return response.Res.text(200, "drain");
            }
        };

        const Item = struct {
            pub const Info: router.EndpointInfo = .{
                .path = struct {
                    id: parse.Int(u32),
                },
            };
            pub fn call(comptime rctx: ReqCtx, req: rctx.T()) !response.Res {
                const body = try std.fmt.allocPrint(req.allocator(), "{d}", .{req.paramValue(.id)});
                return response.Res.text(200, body);
            }
        };

        const Search = struct {
            pub const Info: router.EndpointInfo = .{
                .query = struct {
                    name: parse.Optional(parse.String),
                },
            };
            pub fn call(comptime _: ReqCtx, req: anytype) !response.Res {
                return response.Res.text(200, req.queryParam(.name) orelse "none");
            }
        };
    };

    const io = std.testing.io;
    primeSocketBackend();

    const SrvT = Server(.{
        .routes = .{
            router.get("/ok", Endpoints.Ok),
            router.post("/drain", Endpoints.Drain),
            router.get("/item/{id}", Endpoints.Item),
            router.get("/search", Endpoints.Search),
        },
        .config = .{
            .read_buffer = 1024,
            .write_buffer = 1024,
            .max_request_line = 128,
            .max_single_header_size = 128,
            .max_header_bytes = 512,
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, {});
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    var bad_400_buf: [256]u8 = undefined;
    const bad_400 = try renderTextResponse(400, "bad request", false, true, bad_400_buf[0..]);
    var bad_414_buf: [256]u8 = undefined;
    const bad_414 = try renderTextResponse(414, "bad request", false, true, bad_414_buf[0..]);
    var bad_431_buf: [256]u8 = undefined;
    const bad_431 = try renderTextResponse(431, "bad request", false, true, bad_431_buf[0..]);
    var ok_close_buf: [256]u8 = undefined;
    const ok_close = try renderTextResponse(200, "ok", false, true, ok_close_buf[0..]);

    try sendOneShotExpect(io, port, "GET http://x HTTP/1.1\r\n\r\n", bad_400);

    var long_uri_req_buf: [256]u8 = undefined;
    {
        var w = Io.Writer.fixed(long_uri_req_buf[0..]);
        try w.writeAll("GET /");
        var i: usize = 0;
        while (i < 150) : (i += 1) try w.writeByte('a');
        try w.writeAll(" HTTP/1.1\r\n\r\n");
        try sendOneShotExpect(io, port, long_uri_req_buf[0..w.end], bad_414);
    }

    var huge_header_req_buf: [512]u8 = undefined;
    {
        var w = Io.Writer.fixed(huge_header_req_buf[0..]);
        try w.writeAll("GET /ok HTTP/1.1\r\nX: ");
        var i: usize = 0;
        while (i < 180) : (i += 1) try w.writeByte('b');
        try w.writeAll("\r\n\r\n");
        try sendOneShotExpect(io, port, huge_header_req_buf[0..w.end], bad_431);
    }

    try sendOneShotExpect(io, port, "GET /ok HTTP/1.1\r\nBroken\r\n\r\n", bad_400);
    try sendOneShotExpect(io, port, "POST /drain HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n", bad_400);
    try sendOneShotExpect(io, port, "POST /drain HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n", bad_400);
    try sendOneShotExpect(io, port, "POST /drain HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\r\naXY0\r\n\r\n", bad_400);
    try sendOneShotExpect(io, port, "GET /item/%ZZ HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", bad_400);
    try sendOneShotExpect(io, port, "GET /search?name=%ZZ HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", bad_400);
    try sendAndCloseEarly(io, port, "GET /ok HTTP/1.1\r\nHost: x");
    try sendAndCloseEarly(io, port, "POST /drain HTTP/1.1\r\nHost: x\r\nContent-Length: 8\r\n\r\nabc");
    try sendAndCloseEarly(io, port, "POST /drain HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab");

    try sendOneShotExpect(io, port, "GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", ok_close);
}

test "server soak: deterministic real-socket variety including malformed keepalive and upgrade flows" {
    const Ctx = struct {
        upgrades: usize = 0,
    };

    const Endpoints = struct {
        const Ok = struct {
            pub const Info: router.EndpointInfo = .{};
            pub fn call(comptime _: ReqCtx, _: anytype) !response.Res {
                return response.Res.text(200, "ok");
            }
        };

        const Echo = struct {
            pub const Info: router.EndpointInfo = .{};
            pub fn call(comptime _: ReqCtx, req: anytype) !response.Res {
                const body = try req.bodyAll(1024);
                const out = try std.fmt.allocPrint(req.allocator(), "echo:{s}", .{body});
                return response.Res.text(200, out);
            }
        };

        const Drain = struct {
            pub const Info: router.EndpointInfo = .{};
            pub fn call(comptime _: ReqCtx, _: anytype) !response.Res {
                return response.Res.text(200, "drain");
            }
        };

        const Item = struct {
            pub const Info: router.EndpointInfo = .{
                .path = struct {
                    id: parse.Int(u32),
                },
            };
            pub fn call(comptime _: ReqCtx, req: anytype) !response.Res {
                const out = try std.fmt.allocPrint(req.allocator(), "{d}", .{req.paramValue(.id)});
                return response.Res.text(200, out);
            }
        };

        const Search = struct {
            pub const Info: router.EndpointInfo = .{
                .query = struct {
                    name: parse.Optional(parse.String),
                },
            };
            pub fn call(comptime _: ReqCtx, req: anytype) !response.Res {
                return response.Res.text(200, req.queryParam(.name) orelse "none");
            }
        };

        const Upgrade = struct {
            pub const Info: router.EndpointInfo = .{};
            pub fn call(comptime _: ReqCtx, _: anytype) !response.Res {
                return .{
                    .status = .switching_protocols,
                    .headers = &.{
                        .{ .name = "connection", .value = "Upgrade" },
                        .{ .name = "upgrade", .value = "testproto" },
                    },
                };
            }
            pub fn upgrade(server: anytype, stream: *const std.Io.net.Stream, r: *Io.Reader, w: *Io.Writer, _: request.RequestLine, _: response.Res) void {
                server.ctx.upgrades += 1;
                var msg: [4]u8 = undefined;
                r.readSliceAll(msg[0..]) catch {
                    stream.close(server.io);
                    return;
                };
                if (std.mem.eql(u8, msg[0..], "ping")) {
                    w.writeAll("pong") catch {};
                    w.flush() catch {};
                }
                stream.close(server.io);
            }
        };
    };

    const io = std.testing.io;
    primeSocketBackend();

    var ctx: Ctx = .{};
    const SrvT = Server(.{
        .Context = Ctx,
        .routes = .{
            router.get("/ok", Endpoints.Ok),
            router.head("/ok", Endpoints.Ok),
            router.post("/echo", Endpoints.Echo),
            router.post("/drain", Endpoints.Drain),
            router.get("/item/{id}", Endpoints.Item),
            router.get("/search", Endpoints.Search),
            router.get("/up", Endpoints.Upgrade),
        },
        .config = .{
            .read_buffer = 1024,
            .write_buffer = 1024,
            .max_request_line = 256,
            .max_single_header_size = 256,
            .max_header_bytes = 1024,
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, &ctx);
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    var prng = std.Random.DefaultPrng.init(0x5eed_cafe_1234_5678);
    const random = prng.random();
    const soak_case_count = 18;
    var upgrade_cases: usize = 0;
    var malformed_cases: usize = 0;
    var keepalive_cases: usize = 0;
    var mandatory_case: usize = 0;
    while (mandatory_case < soak_case_count) : (mandatory_case += 1) {
        try runSoakVarietyCase(io, port, random, mandatory_case, &upgrade_cases, &malformed_cases, &keepalive_cases);
    }

    const extra_iterations: usize = soak_case_count * 4;
    var extra_iter: usize = 0;
    while (extra_iter < extra_iterations) : (extra_iter += 1) {
        try runSoakVarietyCase(io, port, random, extra_iter % soak_case_count, &upgrade_cases, &malformed_cases, &keepalive_cases);
    }

    try std.testing.expect(upgrade_cases != 0);
    try std.testing.expect(malformed_cases != 0);
    try std.testing.expect(keepalive_cases != 0);
    try std.testing.expect(ctx.upgrades == upgrade_cases);
}

test "server websocket abuse: helper handshake and hostile frame mix" {
    const Ctx = struct {
        upgrades: usize = 0,
    };

    const Ws = struct {
        pub const Info: router.EndpointInfo = .{
            .headers = upgrade_mod.WebSocketHeaders,
        };

        pub fn call(comptime _: ReqCtx, req: anytype) !response.Res {
            return upgrade_mod.acceptWebSocket(req, .{}) catch |err| return upgrade_mod.rejectWebSocket(err);
        }

        pub fn upgrade(server: anytype, stream: *const std.Io.net.Stream, r: *Io.Reader, w: *Io.Writer, _: request.RequestLine, _: response.Res) void {
            server.ctx.upgrades += 1;
            defer stream.close(server.io);

            var conn = zws.ServerConn.init(r, w, .{
                .max_frame_payload_len = 64,
                .max_message_payload_len = 128,
            });
            var msg_buf: [128]u8 = undefined;

            while (true) {
                const msg = conn.readMessage(msg_buf[0..]) catch |err| {
                    switch (err) {
                        error.EndOfStream,
                        error.ConnectionClosed,
                        error.ReadFailed,
                        error.WriteFailed,
                        => return,
                        error.InvalidUtf8 => {
                            conn.writeClose(1007, "") catch {};
                            conn.flush() catch {};
                            return;
                        },
                        error.FrameTooLarge, error.MessageTooLarge => {
                            conn.writeClose(1009, "") catch {};
                            conn.flush() catch {};
                            return;
                        },
                        error.Timeout,
                        error.FrameActive,
                        error.NoActiveFrame,
                        error.FragmentWriteInProgress,
                        error.UnexpectedContinuationWrite,
                        => {
                            conn.writeClose(1011, "") catch {};
                            conn.flush() catch {};
                            return;
                        },
                        error.InvalidCompressedMessage,
                        error.InvalidClosePayload,
                        error.InvalidCloseCode,
                        error.ReservedBitsSet,
                        error.UnknownOpcode,
                        error.InvalidFrameLength,
                        error.MaskBitInvalid,
                        error.UnexpectedContinuation,
                        error.ExpectedContinuation,
                        error.ControlFrameFragmented,
                        error.ControlFrameTooLarge,
                        => {
                            conn.writeClose(1002, "") catch {};
                            conn.flush() catch {};
                            return;
                        },
                        error.OutOfMemory => {
                            conn.writeClose(1011, "") catch {};
                            conn.flush() catch {};
                            return;
                        },
                    }
                };

                switch (msg.opcode) {
                    .text => {
                        conn.writeText(msg.payload) catch return;
                    },
                    .binary => {
                        conn.writeBinary(msg.payload) catch return;
                    },
                }
                conn.flush() catch return;
            }
        }
    };

    const io = std.testing.io;
    primeSocketBackend();

    var ctx: Ctx = .{};
    const SrvT = Server(.{
        .Context = Ctx,
        .routes = .{
            router.get("/ws", Ws),
        },
        .config = .{
            .read_buffer = 4096,
            .write_buffer = 2048,
            .max_request_line = 512,
            .max_single_header_size = 512,
            .max_header_bytes = 2048,
        },
    });

    const addr0: Io.net.IpAddress = .{ .ip4 = Io.net.Ip4Address.loopback(0) };
    var group: Io.Group = .init;
    var server = try SrvT.initOwned(std.testing.allocator, io, addr0, &ctx);
    defer stopServerTest(io, &group, &server);
    const port: u16 = server.listener.socket.address.getPort();

    try group.concurrent(io, SrvT.serve, .{ &server, .{} });

    var exercised: usize = 0;

    // Baseline round-trip for normal websocket traffic.
    {
        var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [8 * 1024]u8 = undefined;
        var wb: [8 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);
        try performWebSocketHandshake(&sr.interface, &sw.interface, "/ws");
        var client = zws.ClientConn.init(&sr.interface, &sw.interface, .{});
        var msg_buf: [256]u8 = undefined;

        try client.writeText("hello");
        try sw.interface.flush();
        const msg = try client.readMessage(msg_buf[0..]);
        try std.testing.expectEqual(zws.MessageOpcode.text, msg.opcode);
        try std.testing.expectEqualStrings("hello", msg.payload);
        try client.writeClose(null, "");
        try sw.interface.flush();
        _ = client.readMessage(msg_buf[0..]) catch {};
        exercised += 1;
    }

    // Control frame path should respond with pong.
    {
        var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [8 * 1024]u8 = undefined;
        var wb: [8 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);
        try performWebSocketHandshake(&sr.interface, &sw.interface, "/ws");
        var client = zws.ClientConn.init(&sr.interface, &sw.interface, .{});
        var msg_buf: [256]u8 = undefined;
        try client.writePing("zz");
        try sw.interface.flush();
        const pong = try client.readFrame(msg_buf[0..]);
        try std.testing.expectEqual(zws.Opcode.pong, pong.header.opcode);
        try std.testing.expectEqualStrings("zz", pong.payload);
        try client.writeClose(null, "");
        try sw.interface.flush();
        _ = client.readMessage(msg_buf[0..]) catch {};
        exercised += 1;
    }

    // Invalid unmasked client frame should fail the upgraded connection.
    {
        var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [8 * 1024]u8 = undefined;
        var wb: [8 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);
        try performWebSocketHandshake(&sr.interface, &sw.interface, "/ws");
        var client = zws.ClientConn.init(&sr.interface, &sw.interface, .{});
        var frame_buf: [256]u8 = undefined;

        const bad_unmasked = try appendClientFrame(frame_buf[0..], 0x1, "bad", true, false, false);
        try sw.interface.writeAll(bad_unmasked);
        try sw.interface.flush();
        const close_frame = try client.readFrame(frame_buf[0..]);
        try std.testing.expectEqual(zws.Opcode.close, close_frame.header.opcode);
        try expectClosed(&sr.interface);
        exercised += 1;
    }

    // Oversized payload should also fail the upgraded connection.
    {
        var stream = try Io.net.IpAddress.connect(&.{ .ip4 = Io.net.Ip4Address.loopback(port) }, io, .{ .mode = .stream });
        defer stream.close(io);

        var rb: [8 * 1024]u8 = undefined;
        var wb: [8 * 1024]u8 = undefined;
        var sr = stream.reader(io, &rb);
        var sw = stream.writer(io, &wb);
        try performWebSocketHandshake(&sr.interface, &sw.interface, "/ws");
        var client = zws.ClientConn.init(&sr.interface, &sw.interface, .{});
        var frame_buf: [256]u8 = undefined;
        var payload: [80]u8 = .{'x'} ** 80;
        const too_big = try appendClientFrame(frame_buf[0..], 0x2, payload[0..], true, true, false);
        try sw.interface.writeAll(too_big);
        try sw.interface.flush();
        const close_frame = try client.readFrame(frame_buf[0..]);
        try std.testing.expectEqual(zws.Opcode.close, close_frame.header.opcode);
        try expectClosed(&sr.interface);
        exercised += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), exercised);
    try std.testing.expect(ctx.upgrades >= exercised);
}
