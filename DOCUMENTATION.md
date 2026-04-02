# zhttp Middleware and Operations Documentation

This document is the detailed guide for extending `zhttp` with:

- custom middlewares (runtime request/response behavior), and
- custom operations (compile-time route-table transforms).

It also explains the design decisions behind the current API.

## 1. Mental Model

`zhttp` has two extension layers:

1. Runtime layer: middlewares + endpoint handlers.
2. Compile-time layer: operations that mutate the route table before runtime.

Route registration is endpoint-first:

```zig
zhttp.get("/users/{id}", UserEndpoint)
```

Each endpoint type provides metadata in `EndpointInfo`:

- captures (`headers`, `query`, `path`)
- per-endpoint middlewares
- per-endpoint operation tags

Global middlewares/operations are configured in `Server(.{ ... })`.

## 1.1 Type/Anytype Shape Contracts (Function-by-Function)

This section is the explicit contract for every public API that takes `type`/`anytype` style inputs.

### Endpoint and server contracts

- `zhttp.Server(def: anytype)`
  - `def.routes` is required and is a tuple/struct of `zhttp.get/post/...` route declarations.
  - optional `def.middlewares` is a middleware tuple (`.{ MwA, MwB, ... }`).
  - optional `def.operations` is an operation tuple (`.{ OpA, OpB, ... }`).
  - each route endpoint type must expose:
    - `pub const Info: zhttp.router.EndpointInfo`
    - `pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !rctx.Response(Body)`
    - optional upgrade hook:
      `pub fn upgrade(server, stream, r, w, line, res) void`

- `zhttp.router.route(..., endpoint: type)` and `zhttp.router.get/post/put/delete/patch/head/options`
  - same endpoint shape as above.

- `zhttp.router.Compiled(Context, routes: anytype, global_middlewares: anytype)`
  - `routes` is a tuple of `RouteDecl` values.
  - `global_middlewares` is accepted by `middleware.typeList` (tuple / `[]const type` / `[N]type` / `*const [N]type`).

### Middleware contracts

- `zhttp.middleware.info(Mw: type)`
  - middleware type must expose:
    - `pub const Info: zhttp.middleware.MiddlewareInfo`
    - `pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !Res`

- `zhttp.middleware.needsHeaders/needsQuery/needsParams(mws: anytype)`
- `zhttp.middleware.contextType(mws: anytype)`
- `zhttp.middleware.staticContextType(mws: anytype)`
- `zhttp.middleware.contextST(mws: anytype)`
  - `mws` must be accepted by `zhttp.middleware.typeList`.
  - each middleware in `mws` must satisfy `middleware.info(...)` checks.

- `zhttp.middleware.initContext(mws: anytype, Ctx: type)`
  - `Ctx` must be the exact type returned by `contextType(mws)`.

- `zhttp.middleware.initStaticContext(Ctx: type, ...)` / `deinitStaticContext(Ctx: type, ...)`
  - `Ctx` should be the exact type returned by `staticContextType(...)`.
  - each static context field type may expose:
    - `pub fn init(io: std.Io, allocator: std.mem.Allocator, route_decl: zhttp.route_decl.RouteDecl) Self | !Self`
    - `pub fn deinit(self: *Self, io: std.Io, allocator: std.mem.Allocator) void | !void`

- `zhttp.middleware.typeList(mws: anytype)`
  - accepted input shapes:
    - tuple of middleware types
    - `[]const type`
    - `[N]type`
    - `*const [N]type`

### Operation contracts

- `zhttp.operations.apply(routes_tuple: anytype, global_middlewares_tuple: anytype, operations_tuple: anytype)`
  - `routes_tuple` is a tuple of `RouteDecl`.
  - `global_middlewares_tuple` is accepted by `middleware.typeList`.
  - each operation type in `operations_tuple` exposes:
    - `pub fn operation(comptime opctx: zhttp.operations.OperationCtx, router: opctx.T()) void`
    - optional `pub fn maxAddedRoutes(comptime base_route_count: usize) usize`

### Response/body contracts

- `zhttp.response.Response(Body: type)`
  - `Body` can be:
    - `[]const u8`
    - `[][]const u8`
    - `void`
    - custom struct with:
      `pub fn body(self: @This(), comptime rctx: zhttp.ReqCtx, req: rctx.TReadOnly(), cw: *zhttp.response.ChunkedWriter) !void`
  - endpoint handlers may also return a prebuilt response struct instead of `Response(Body)` when it exposes:
    `pub fn write(self: @This(), w: *std.Io.Writer, keep_alive: bool, send_body: bool) !void`
    and optional `close: bool`
  - server dispatch automatically bypasses the per-connection writer buffer for these prebuilt writes

- `zhttp.response.writeAny(rctx: anytype, req_ro: anytype, w, res: anytype, ...)`
  - `rctx` is a `zhttp.ReqCtx` value.
  - `req_ro` is `rctx.TReadOnly()`.
  - `res` is `zhttp.response.Response(Body)` (or a compatible struct with `status`, `headers`, `body`, optional `close`).
  - prebuilt response structs expose:
    `pub fn write(self: @This(), w: *std.Io.Writer, keep_alive: bool, send_body: bool) !void`
  - `keep_alive` and `send_body` are already resolved to the effective connection/body policy for that request

- `zhttp.response.writeUpgrade(w, res: anytype)`
  - `res` must expose `status` and `headers`.

### Request parsing and request-wrapper contracts

- `zhttp.request.RequestPWithPatternExt(ServerPtr: type, route_index, rd, MwCtx)`
  - `ServerPtr` is `*Server` where pointee exposes:
    - fields: `io`, `gpa`, `ctx`
    - `RouteStaticType(route_index)`
    - `routeStatic(route_index)`
    - `routeStaticConst(route_index)`
  - `rd` is a resolved `RouteDecl`.
  - `MwCtx` is merged middleware request-context type for that route.

- `zhttp.request.Request(Headers: type, Query: type, param_names, MwCtx: type)`
  - `Headers` and `Query` are capture structs whose field types follow parser contract (below).
  - `MwCtx` is the middleware context struct type.

- request helpers that take `name: anytype`:
  - `req.middlewareData(name)`
  - `req.middlewareDataConst(name)`
  - `req.middlewareStatic(name)`
  - `req.middlewareStaticConst(name)`
  - accepted `name` shapes:
    - enum literal (for example `.auth`)
    - string/byte-array literal (for example `"auth"`)

### Upgrade helper contracts

- `zhttp.upgrade.websocketHandshakeRequest(req: anytype)`
  - `req` must expose:
    - `method`
    - `baseConst().version`
    - `header(.connection/.upgrade/.sec_websocket_key/.sec_websocket_version/.sec_websocket_protocol/.sec_websocket_extensions/.origin/.host)`

- `zhttp.upgrade.acceptWebSocket(req: anytype, opts)`
  - same requirements as `websocketHandshakeRequest(req)`
  - plus `req.allocator()`.

### Parse helper contracts

Parser field type contract used by `zhttp.parse` helpers:

```zig
const Parser = struct {
    pub const empty: @This() = .{};
    pub fn parse(self: *@This(), allocator: std.mem.Allocator, raw: []const u8) !void {}
    pub fn doneParsing(self: *@This(), was_present: bool) !void {}
    pub fn get(self: *const @This()) ValueType { ... }
    pub fn destroy(self: *@This(), allocator: std.mem.Allocator) void {}
};
```

- `zhttp.parse.structFields(T: type)` -> `T` must be `struct`.
- `zhttp.parse.emptyStruct(T: type)` -> every field type in `T` provides `empty`.
- `zhttp.parse.destroyStruct(value: anytype, allocator)` -> `value` is `*Struct`, fields provide `destroy`.
- `zhttp.parse.doneParsingStruct(value: anytype, present)` -> `value` is `*Struct`, fields provide `doneParsing`, `present.len` matches field count.
- `zhttp.parse.Lookup(T: type, kind)` -> `T` is `struct` capture schema with no duplicate keys after normalization.
- `zhttp.parse.mergeStructs(A: type, B: type)` -> both structs; duplicate field names must have identical types.
- `zhttp.parse.mergeHeaderStructs(A: type, B: type)` -> same as above but key matching is case-insensitive and `_` equals `-`.
- `zhttp.parse.mergeStructsMany(types_tuple: anytype)` -> tuple of struct types.
- `zhttp.parse.Optional(P: type)` / `zhttp.parse.SliceOf(P: type)` -> `P` follows parser contract.
- `zhttp.parse.Int(T: type)` -> integer type.
- `zhttp.parse.Float(T: type)` -> float type.
- `zhttp.parse.Enum(E: type)` -> enum type.

## 2. Writing a Middleware

## 2.1 Required shape

A middleware is a `type` that exposes:

- `pub const Info: zhttp.middleware.MiddlewareInfo`
- `pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !rctx.Response(Body)`

`Body` follows the same rules as endpoints:

- `[]const u8`
- `[][]const u8`
- `void`
- custom struct with `pub fn body(self, comptime rctx, req: rctx.TReadOnly(), cw) !void`

Minimal example:

```zig
const Auth = struct {
    pub const Info = zhttp.middleware.MiddlewareInfo{
        .name = "auth",
        .header = struct {
            authorization: zhttp.parse.Optional(zhttp.parse.String),
        },
        .data = struct {
            user_id: u64 = 0,
        },
    };

    pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !rctx.Response([]const u8) {
        const auth = req.header(.authorization) orelse
            return zhttp.Res.text(401, "missing auth\n");

        if (!std.mem.eql(u8, auth, "bearer ok")) {
            return zhttp.Res.text(403, "bad auth\n");
        }

        req.middlewareData(.auth).user_id = 42;
        return rctx.next(req);
    }
};
```

## 2.2 `MiddlewareInfo` fields

`MiddlewareInfo` is the only public metadata contract for middlewares:

- `name: []const u8` required unique middleware key.
- `data: ?type` optional per-request mutable state storage.
- `static_context: ?type` optional per-route startup-initialized state.
- `path: ?type` optional required path captures.
- `query: ?type` optional required query captures.
- `header: ?type` optional required header captures.

Legacy public `Data/Needs` patterns are no longer supported.

## 2.3 Capture merge rules

For a route, zhttp merges endpoint captures with all middleware capture needs.

Rules:

- `path`/`query` merges are exact-name merges.
- `header` merges are normalized merges:
  - case-insensitive
  - `_` and `-` are treated as equivalent
- same normalized header + same field type: coalesced (allowed).
- same normalized header + different type: compile error.

These are enforced at compile time.

## 2.4 Middleware ordering and chain behavior

Execution order is deterministic:

1. global middlewares (from `Server(.middlewares)`), then
2. endpoint middlewares (from `EndpointInfo.middlewares`), then
3. endpoint `call`.

`rctx.next(req)` advances the chain.

Patterns:

- Guard middleware: return early (`401/403/...`) without `next`.
- Transform middleware: call `next`, then edit response headers/body metadata.
- State middleware: write to `req.middlewareData(...)`, later read in endpoint/other middleware.

## 2.5 Per-request middleware state (`Info.data`)

If `Info.data` is non-null and non-zero-sized, zhttp stores it per request.

Access:

- mutable: `req.middlewareData(.name_or_string)`
- read-only: `req.middlewareDataConst(...)`

Name dedup behavior:

- same `Info.name` + same `data` type: shared field (coalesced).
- same `Info.name` + different `data` type: compile error.

## 2.6 Per-route static state (`Info.static_context`)

`static_context` is initialized once per route in `Server.init`.

Type can expose:

```zig
pub fn init(io: std.Io, allocator: std.mem.Allocator, route_decl: zhttp.route_decl.RouteDecl) Self | !Self
```

If omitted, zero-init is used.

Access:

- mutable: `req.middlewareStatic(...)`
- read-only: `req.middlewareStaticConst(...)`

Init errors propagate out of `Server.init`.

## 2.7 Optional request-method overrides (`Override`)

A middleware may optionally expose:

```zig
pub fn Override(comptime rctx: zhttp.ReqCtx) type
```

Returned type can override base request methods (`header`, `bodyAll`, etc.).

Important constraints:

- first parameter must be `rctx.T()`, `*rctx.T()`, or `*const rctx.T()`.
- parameter count must match the base method (zhttp supports at most one extra arg beyond `req`).
- this is optional; most middlewares should not implement it.

`rctx.TReadOnly()` is the override-free request view. It exposes the same surface as
`rctx.T()` but dispatches directly to the base request implementation instead of
walking the middleware override chain.

Use `Override` only for cross-cutting request behavior changes.

## 2.9 Middleware and Response Bodies

Response bodies may be:

- `[]const u8` for one contiguous body
- `[][]const u8` for vectored fixed-length bodies
- `void` for empty bodies
- a custom body struct with `pub fn body(self, comptime rctx, req: rctx.TReadOnly(), cw) !void`

Request body accessors available to middleware and endpoints:

- `req.bodyAll(max_bytes)` reads and caches the full body
- `req.bodyReader()` returns a one-way body reader for streaming consumers
- `req.allocator()` uses request-lifetime allocation
- `req.gpa()` returns the server allocator and must be freed manually

## 2.8 Middleware checklist

Before shipping a middleware:

1. `Info.name` stable and non-empty.
2. captures declared only in `MiddlewareInfo` (`path/query/header`).
3. short-circuit and pass-through paths both tested.
4. duplicate-header behavior tested (`assert_absent` or `check_then_add` style).
5. if using `static_context`, init success/failure paths tested.

## 3. Writing an Operation

## 3.1 What operations are

Operations are compile-time route-table transforms.

They can add/remove/replace routes before runtime starts.
They do not run per request.

## 3.2 Required shape

Operation type must expose:

```zig
pub fn operation(comptime opctx: zhttp.operations.OperationCtx, router: opctx.T()) void
```

Optional capacity budget (at least one of):

- `pub const MaxAddedRoutes: usize`
- `pub fn maxAddedRoutes(comptime base_route_count: usize) usize`

If omitted, budget is zero.

## 3.3 Two-step operation activation

Operations are opt-in in two places:

1. tag route endpoints with `EndpointInfo.operations = &.{MyOp}`
2. register execution order in `Server(.{ .operations = .{MyOp, ...} })`

`opctx.filter(router)` returns only indices tagged with the current operation type.

## 3.4 Router API available inside operations

The operation router supports compile-time mutations and queries:

- mutate: `add`, `addMany`, `insert`, `replace`, `remove`, `swapRemove`, `clear`
- inspect: `count`, `all`, `route`, `routeConst`
- lookup: `hasMethodPath`
- middleware/operation queries:
  - `hasMiddleware`, `hasSignature`, `hasMiddlewareDecl`
  - `firstMiddlewareWithSignature`, `firstMiddlewareWithDecl`, `firstMiddlewareWithDeclValue`
  - `filterByMiddleware`, `filterBySignature`, `filterByMiddlewareDecl`, `filterByOperation`
  - path grouping helpers (`forEachPathGroup*`)

## 3.5 Example operation

```zig
const AutoHead = struct {
    pub fn maxAddedRoutes(comptime base_route_count: usize) usize {
        return base_route_count;
    }

    pub fn operation(comptime opctx: zhttp.operations.OperationCtx, r: opctx.T()) void {
        for (opctx.filter(r)) |idx| {
            const rd = r.routeConst(idx).*;
            if (!std.mem.eql(u8, rd.method, "GET")) continue;
            if (r.hasMethodPath("HEAD", rd.pattern)) continue;
            r.add(zhttp.head(rd.pattern, rd.endpoint));
        }
    }
};
```

Route opt-in:

```zig
const Endpoint = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .operations = &.{AutoHead},
    };
    pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !rctx.Response([]const u8) { ... }
};

const App = zhttp.Server(.{
    .operations = .{AutoHead},
    .routes = .{ zhttp.get("/x", Endpoint) },
});
```

## 3.6 Operation checklist

1. define explicit added-route budget.
2. ensure transform is deterministic for tuple order.
3. ensure idempotency (`hasMethodPath` checks before add).
4. test both tagged and untagged routes.
5. test order interactions with other operations.

## 4. Design Decisions

## 4.1 Endpoint-first metadata (`EndpointInfo`)

All per-route behavior (captures, middlewares, operation tags) lives on endpoint types.
This keeps route registration minimal and avoids split metadata between route call sites and handler types.

## 4.2 Middleware requirements in one struct (`MiddlewareInfo`)

Capture requirements and state shape are declared once.
This enables compile-time merging, validation, and deterministic request wrapper generation.

## 4.3 Strict header normalization

Headers are case-insensitive and `-`/`_` equivalent in field names.
Coalescing same-type duplicates prevents noisy conflicts while still catching true schema mismatches.

## 4.4 `static_context` as startup-only initialization

Expensive route-derived setup belongs in startup, not request hot paths.
`static_context` provides exactly that and keeps per-request work minimal.

## 4.5 Tagged operations + global operation order

Tagging expresses *where* an operation applies.
Server operation tuple expresses *when* it runs.
This separates scope from sequencing and makes transforms composable.

## 4.6 Route budgeting for operations

Operation router capacity is fixed at compile time (base routes + budgets).
This avoids dynamic growth logic and preserves deterministic compile-time behavior.

## 4.7 Strong compile-time contracts

Most extension errors are compile-time errors:

- missing/invalid `Info`
- invalid operation signatures
- conflicting capture schemas
- route collisions

This is intentional: fail early, keep runtime fast.

## 4.8 Optional request overrides

`Override` exists for advanced request-behavior interception, but is optional by design.
Most middleware should remain simple (`Info` + `call` + optional state).

## 4.9 Readonly request views for body writers

Custom response body writers run after middleware/endpoint code has already produced
the response metadata. They therefore receive `rctx.TReadOnly()` instead of `rctx.T()`.
This keeps the request API available while avoiding another middleware-override pass
during response streaming.

## 5. Testing Guidance

For middleware/operation contributions, add tests that cover:

- happy path
- failure/short-circuit path
- merge/conflict behavior
- ordering semantics
- startup init errors (for `static_context`)
- operation idempotency and budget assumptions

## 6. Endpoint Response Body Types

Endpoints select response serialization mode via `rctx.Response(Body)`:

- `Body = []const u8`: normal `Content-Length` response.
- `Body = [][]const u8`: vectored body, still `Content-Length`.
- `Body = CustomBody`: chunked response (`transfer-encoding: chunked`).
- returning a custom struct with `pub fn write(self, w, keep_alive, send_body) !void`: prebuilt response bytes
  written directly to an unbuffered stream writer by the server

Chunked example:

```zig
const StreamEp = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !rctx.Response(CustomBody) {
        _ = req;
        return .{
            .status = .ok,
            .body = .{ .writeFn = struct {
                fn write(cw: *zhttp.response.ChunkedWriter) std.Io.Writer.Error!void {
                    try cw.writeAll("part-a");
                    try cw.writeAll("part-b");
                }
            }.write },
        };
    }
};
```

Prebuilt write example:

```zig
const Prebuilt = struct {
    pub fn write(_: @This(), w: *std.Io.Writer, keep_alive: bool, send_body: bool) !void {
        try w.writeAll(if (keep_alive)
            if (send_body)
                "HTTP/1.1 200 OK\r\nconnection: keep-alive\r\ncontent-length: 2\r\n\r\nok"
            else
                "HTTP/1.1 200 OK\r\nconnection: keep-alive\r\ncontent-length: 2\r\n\r\n"
        else if (send_body)
            "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 2\r\n\r\nok"
        else
            "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-length: 2\r\n\r\n");
    }
};

const PrebuiltEp = struct {
    pub const Info: zhttp.router.EndpointInfo = .{};

    pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !Prebuilt {
        _ = req;
        return .{};
    }
};
```

Recommended validation commands:

```sh
zig build test
zig build test-flake -- --iterations=100 --jobs=1
zig build test-flake -- --iterations=200 --jobs=1 --retries=5 --test-filter="Server stop"
zig build examples-check
zig build -Doptimize=ReleaseFast test
zig build -Doptimize=ReleaseFast examples-check
```

`test-flake` runs the test runner across a deterministic seed sweep and, on failure, extracts failing test lines, prints single-test repro commands (`--zhttp-run-test` + `--seed`), and reports rerun reproducibility for that seed. It only returns failure for seeds that reproduce on rerun(s). Pass `--verbose` to include full failing logs.
