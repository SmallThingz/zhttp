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

## 2. Writing a Middleware

## 2.1 Required shape

A middleware is a `type` that exposes:

- `pub const Info: zhttp.middleware.MiddlewareInfo`
- `pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !zhttp.Res` (or compatible response type for your routes)

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

    pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !zhttp.Res {
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
pub fn init(io: std.Io, allocator: std.mem.Allocator, route_decl: anytype) Self | !Self
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

Use `Override` only for cross-cutting request behavior changes.

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
    pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !zhttp.Res { ... }
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

## 5. Testing Guidance

For middleware/operation contributions, add tests that cover:

- happy path
- failure/short-circuit path
- merge/conflict behavior
- ordering semantics
- startup init errors (for `static_context`)
- operation idempotency and budget assumptions

Recommended validation commands:

```sh
zig build test
zig build examples-check
zig build -Doptimize=ReleaseFast test
zig build -Doptimize=ReleaseFast examples-check
```

