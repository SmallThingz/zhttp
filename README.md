# zhttp

Low-latency HTTP/1.1 server primitives for Zig (comptime router + typed captures).

## Quick start

This is a library. For a minimal runnable server example, see `benchmark/zhttp_server.zig`.

## Examples

- Build all examples: `zig build examples`
- Smoke-check examples (runs each with `--smoke`): `zig build examples-check`

## `Server(.{ ... })` definition fields

- `.Context: type` (optional) user context passed to handlers/middlewares. Defaults to `void`.
- `.middlewares: tuple` (optional) global middleware types. Defaults to `.{}`.
- `.routes: struct` (required) route registrations, e.g. `.{ zhttp.get(...), ... }`.
- `.config: struct` (optional) config overrides (fields match `zhttp.server.Config`).
- `.error_handler: fn(...) !Res` (optional) global error handler. Defaults to server 500s on handler/middleware errors.
  - Supported signatures: `fn(err)`, `fn(req, err)`, `fn(ctx, err)`, `fn(ctx, req, err)`

## Route registration

Routes are registered at comptime via helpers like:

- `zhttp.get("/path", handler, .{ ...opts... })`
- `zhttp.get("/path", handler, .{})` (no options)

`zhttp.route(.GET, "/path", handler, .{ ...opts... })` is available if you want to specify the method explicitly.

### Route options (`opts`)

`opts` is a comptime struct literal. Supported fields (all optional):

- `.headers: type` request header captures
  - header keys are matched case-insensitively
  - `_` in field names matches `-` in incoming header names
- `.query: type` query string captures (keys match exactly)
- `.params: type` path param captures (for `{name}` segments)
  - if omitted, path params default to strings
- `.middlewares: tuple` per-route middleware types

Each capture schema is a `struct` where field values are parsers from `zhttp.parse`:

```zig
.{
  .headers = struct { host: zhttp.parse.Optional(zhttp.parse.String) },
  .query = struct { page: zhttp.parse.Optional(zhttp.parse.Int(u32)) },
  .params = struct { id: zhttp.parse.Int(u64) },
}
```

## Handler signatures

Handlers can be any of:

- `fn() !zhttp.Res`
- `fn(req: anytype) !zhttp.Res`
- `fn(ctx: *Context) !zhttp.Res`
- `fn(ctx: *Context, req: anytype) !zhttp.Res`

## Request API (in handlers/middlewares)

Capture accessors take enum literals (`@EnumLiteral()`), e.g. `.host`, `.page`, `.id`:

- `req.header(.host)` -> typed header capture value
- `req.queryParam(.page)` -> typed query capture value
- `req.paramValue(.id)` -> typed path param capture value (defaults to string if not declared)
- `req.middlewareData(.auth)` -> pointer to middleware data by name

## Middleware API

Middlewares are types with:

- `pub fn call(comptime Next: type, next: Next, ctx: *Context, req: anytype) !zhttp.Res`
- optional `pub const Needs = struct { headers: type = ..., query: type = ..., params: type = ... }`
- optional stored data:
  - `pub const Data = struct { ... }`
  - `pub const name = .your_middleware` (required if `Data` is non-empty)
  - `pub fn initData() Data` (optional; defaults to zero init)
  - with data: `pub fn call(comptime Next: type, next: Next, ctx: *Context, req: anytype, data: *Data) !zhttp.Res`

`Needs.*` captures are merged into the route’s capture schema at comptime.
