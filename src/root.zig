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
pub const parse = @import("parse.zig");

pub const Res = @import("response.zig").Res;
pub const Server = @import("server.zig").Server;

pub const route = @import("router.zig").route;
pub const get = @import("router.zig").get;
pub const post = @import("router.zig").post;
pub const put = @import("router.zig").put;
pub const delete = @import("router.zig").delete;
pub const patch = @import("router.zig").patch;
pub const head = @import("router.zig").head;
pub const options = @import("router.zig").options;

test {
    _ = @import("parse.zig");
    _ = @import("request.zig");
    _ = @import("response.zig");
    _ = @import("router.zig");
    _ = @import("server.zig");
    _ = @import("urldecode.zig");
}
