//! zhttp: low-latency HTTP/1.1 server primitives.
//!
//! ## Route registration
//!
//! You register routes at comptime via `zhttp.Server(.{ .routes = .{ ... } })`.
//! Route helpers accept a pattern, a handler, then comptime options:
//!
//! - With options: `zhttp.get("/users/{id}", handler, .{ .params = struct { id: zhttp.parse.Int(u64) } })`
//! - No options: `zhttp.get("/health", handler, .{})`
//!
//! Supported route option fields (all optional):
//! - `.headers: type`    Header capture schema (header keys match case-insensitively; `_` matches `-`)
//! - `.query: type`      Query capture schema (keys match exactly)
//! - `.params: type`     Path param capture schema (for `{name}` segments; defaults to strings)
//! - `.middlewares: tuple` Per-route middleware types
//! - `.upgrade: type`    Optional deferred-upgrade runner type
//!
//! Server definition fields (for `Server(.{ ... })`):
//! - `.Context: type` (optional) user context passed to handlers/middlewares
//! - `.middlewares: tuple` (optional) global middleware types
//! - `.routes: struct` (required) route registrations
//! - `.config: struct` (optional) server config overrides
//! - `.error_handler: fn(...) !Res` (optional) global error handler for handler/middleware errors
//!
//! ## Handler signatures
//!
//! Handlers can be any of:
//! - `fn() !zhttp.Res`
//! - `fn(req: anytype) !zhttp.Res`
//! - `fn(ctx: *Context) !zhttp.Res`
//! - `fn(ctx: *Context, req: anytype) !zhttp.Res`
//!
//! Upgrade-enabled routes
//!
//! When a route declares `.upgrade = WsRunner`, the normal HTTP handler still
//! runs first. If that handler returns `101 Switching Protocols`, `zhttp`
//! writes the response, unwinds the HTTP parser stack, and then calls
//! `WsRunner.run(...)` with the raw `std.Io.net.Stream`.
//! At that point, stream ownership has transferred to `WsRunner`.
//! The HTTP-side stack frame is gone before `WsRunner.run(...)` begins.
//!
//! For upgrade routes, the request gets an `upgrade_data` field:
//! - type is `WsRunner.Data` when declared, otherwise `void`
//! - initialized with `WsRunner.initData()` when present, otherwise zeroed
//!
//! `WsRunner` must declare `pub fn run(...) void` or `pub fn run(...) !void`
//! and may optionally declare:
//! - `pub const Data = type`
//! - `pub fn initData() Data`
//! - `pub fn deinitData(gpa: Allocator, data: *Data) void`
//!
//! Post-upgrade error surface:
//! - after takeover, `zhttp` does not use the HTTP `error_handler`
//! - if `WsRunner.run(...)` returns an error, `zhttp` does not automatically
//!   send websocket close `1011`
//! - if you want a graceful websocket close on runner failure, the runner must
//!   write that close frame itself before returning
//! - stream lifecycle is runner-owned after takeover
const std = @import("std");
const builtin = @import("builtin");
pub const parse = @import("parse.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const router = @import("router.zig");

pub const Res = response.Res;
pub const Server = @import("server.zig").Server;
pub const middleware = @import("middleware/mod.zig");

pub const route = router.route;
pub const get = router.get;
pub const post = router.post;
pub const put = router.put;
pub const delete = router.delete;
pub const patch = router.patch;
pub const head = router.head;
pub const options = router.options;

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
    _ = @import("router.zig");
    _ = @import("server.zig");
    _ = @import("middleware/mod.zig");
    _ = @import("urldecode.zig");
}
