//! zhttp: low-latency HTTP/1.1 server primitives.
//!
//! ## Route registration
//!
//! You register routes at comptime via `zhttp.Server(.{ .routes = .{ ... } })`.
//! Route helpers accept a pattern and an endpoint type:
//!
//! - `zhttp.get("/users/{id}", Endpoint)`
//! - `zhttp.get("/health", Endpoint)`
//!
//! Endpoint types must expose:
//! - `pub const Info: zhttp.router.EndpointInfo = .{ ... }`
//! - `pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !zhttp.Res`
//!
//! `EndpointInfo` fields:
//! - `.headers: ?type`    Header capture schema (header keys match case-insensitively; `_` matches `-`)
//! - `.query: ?type`      Query capture schema (keys match exactly)
//! - `.path: ?type`       Path-param capture schema (for `{name}` / `{*name}` segments; defaults to strings)
//! - `.middlewares: []const type` Per-endpoint middleware types
//! - `.operations: []const type` Per-endpoint operation tags
//!
//! Optional endpoint upgrade hook:
//! - `pub fn upgrade(server, stream, r, w, line, res) void`
//!   If present and `call(...)` returns `101 Switching Protocols`, zhttp writes the upgrade response,
//!   calls this function, and returns `.upgraded` (endpoint upgrade owns connection lifecycle).
//!   Use `zhttp.upgrade.responseFor`, `zhttp.upgrade.websocketResponse`,
//!   or `zhttp.upgrade.websocketResponseWithAccept` to build 101 responses.
//!
//! Server definition fields (for `Server(.{ ... })`):
//! - `.Context: type` (optional) user context exposed through `req.ctx()`
//! - `.middlewares: tuple` (optional) global middleware types
//! - `.routes: struct` (required) route registrations
//! - `.operations: tuple` (optional) route operation types run at comptime in tuple order
//!   Built-ins are `zhttp.operations.Cors` and `zhttp.operations.Static`.
//!   Operation shape: `pub fn operation(comptime opctx: zhttp.operations.OperationCtx, router: opctx.T()) void`.
//!   Operations filter tagged routes themselves via `opctx.filter(router)`.
//! - `.config: struct` (optional) server config overrides
//! - `.error_handler: fn(*Server, *std.Io.Writer, comptime ErrorSet: type, err: ErrorSet) router.Action` (optional)
//!   fallback error handler for user handler/middleware errors; server parse/validation errors stay on the built-in `400`/`414`/`431` path
//! - `.not_found_handler: type` (optional) fallback endpoint type override for route misses
//!
//! ## Endpoint Shape
//!
//! Required route endpoint shape:
//! - `type` exposing `pub const Info: zhttp.router.EndpointInfo`
//! - `type` exposing `pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !zhttp.Res`
//!
//! When `.Context` is configured, it is available only via `req.ctx()`.
//! Standard middleware signature types are exported at top-level:
//! `zhttp.CorsSignature`.
//!
const std = @import("std");
const builtin = @import("builtin");
pub const parse = @import("parse.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const upgrade = @import("upgrade.zig");
pub const router = @import("router.zig");

pub const Res = response.Res;
pub const Server = @import("server.zig").Server;
pub const middleware = @import("middleware.zig");
pub const operations = @import("operations.zig");
pub const OperationCtx = operations.OperationCtx;
pub const CorsSignature = middleware.CorsSignature;

pub const route = router.route;
pub const get = router.get;
pub const post = router.post;
pub const put = router.put;
pub const delete = router.delete;
pub const patch = router.patch;
pub const head = router.head;
pub const options = router.options;
pub const ReqCtx = @import("req_ctx.zig").ReqCtx;

/// Implements fuzz.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *std.testing.Smith) anyerror!void,
    fuzz_opts: std.testing.FuzzInputOptions,
) anyerror!void {
    if (comptime builtin.fuzz) {
        return fuzzBuiltin(context, testOne, fuzz_opts);
    }

    if (fuzz_opts.corpus.len == 0) {
        var smith: std.testing.Smith = .{ .in = "" };
        return testOne(context, &smith);
    }

    for (fuzz_opts.corpus) |input| {
        var smith: std.testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
}

fn fuzzBuiltin(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *std.testing.Smith) anyerror!void,
    fuzz_opts: std.testing.FuzzInputOptions,
) anyerror!void {
    const fuzz_abi = std.Build.abi.fuzz;
    const Smith = std.testing.Smith;
    const Ctx = @TypeOf(context);

    const Wrapper = struct {
        var ctx: Ctx = undefined;
        /// Implements test one c.
        pub fn testOneC() callconv(.c) void {
            var smith: Smith = .{ .in = null };
            testOne(ctx, &smith) catch {};
        }
    };

    Wrapper.ctx = context;

    var cache_dir: []const u8 = ".";
    var map_opt: ?std.process.Environ.Map = null;
    if (std.testing.environ.createMap(std.testing.allocator)) |map| {
        map_opt = map;
        if (map.get("ZIG_CACHE_DIR")) |v| {
            cache_dir = v;
        } else if (map.get("ZIG_GLOBAL_CACHE_DIR")) |v| {
            cache_dir = v;
        }
    } else |_| {}

    fuzz_abi.fuzzer_init(.fromSlice(cache_dir));

    const test_name = @typeName(@TypeOf(testOne));
    fuzz_abi.fuzzer_set_test(Wrapper.testOneC, .fromSlice(test_name));

    for (fuzz_opts.corpus) |input| {
        fuzz_abi.fuzzer_new_input(.fromSlice(input));
    }

    fuzz_abi.fuzzer_main(.forever, 0);

    if (map_opt) |*m| m.deinit();
}

test {
    _ = @import("parse.zig");
    _ = @import("request.zig");
    _ = @import("response.zig");
    _ = @import("upgrade.zig");
    _ = @import("router.zig");
    _ = @import("server.zig");
    _ = @import("middleware.zig");
    _ = @import("operations.zig");
    _ = @import("operations/mod.zig");
    _ = @import("operations/cors.zig");
    _ = @import("operations/static.zig");
    _ = @import("middleware/mod.zig");
    _ = @import("middleware/util.zig");
    _ = @import("middleware/compression.zig");
    _ = @import("middleware/cors.zig");
    _ = @import("middleware/etag.zig");
    _ = @import("middleware/logger.zig");
    _ = @import("middleware/origin.zig");
    _ = @import("middleware/request_id.zig");
    _ = @import("middleware/security_headers.zig");
    _ = @import("middleware/static.zig");
    _ = @import("middleware/timeout.zig");
    _ = @import("urldecode.zig");
}
