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
//! - `.params: type`     Path param capture schema (for `{name}` segments)
//! - `.middlewares: tuple` Per-route middleware types
//!
//! ## Handler signatures
//!
//! Handlers can be any of:
//! - `fn() !zhttp.Res`
//! - `fn(req: anytype) !zhttp.Res`
//! - `fn(ctx: *Context) !zhttp.Res`
//! - `fn(ctx: *Context, req: anytype) !zhttp.Res`
pub const Method = @import("zhttp/server.zig").Method;
pub const Res = @import("zhttp/response.zig").Res;
pub const Server = @import("zhttp/server.zig").Server;

pub const parse = @import("zhttp/parse.zig");

pub const route = @import("zhttp/router.zig").route;
pub const get = @import("zhttp/router.zig").get;
pub const post = @import("zhttp/router.zig").post;
pub const put = @import("zhttp/router.zig").put;
pub const delete = @import("zhttp/router.zig").delete;
pub const patch = @import("zhttp/router.zig").patch;
pub const head = @import("zhttp/router.zig").head;
pub const options = @import("zhttp/router.zig").options;

test {
    _ = @import("zhttp/tests.zig");
}
