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
const std = @import("std");
const builtin = @import("builtin");
pub const parse = @import("parse.zig");

pub const Res = @import("response.zig").Res;
pub const Server = @import("server.zig").Server;
pub const middleware = @import("middleware/mod.zig");

pub const route = @import("router.zig").route;
pub const get = @import("router.zig").get;
pub const post = @import("router.zig").post;
pub const put = @import("router.zig").put;
pub const delete = @import("router.zig").delete;
pub const patch = @import("router.zig").patch;
pub const head = @import("router.zig").head;
pub const options = @import("router.zig").options;

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
