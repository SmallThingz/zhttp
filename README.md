# zhttp

Low-latency HTTP/1.1 server primitives for Zig with comptime routing, typed captures, and composable middleware.

![zig](https://img.shields.io/badge/zig-0.16.0--dev-f7a41d?logo=zig&logoColor=111)
![protocol](https://img.shields.io/badge/protocol-http%2F1.1-0f766e)
![routing](https://img.shields.io/badge/routing-comptime-1d4ed8)
![core](https://img.shields.io/badge/core-pure%20zig-111827)

## Features

- Comptime route table via `zhttp.Server(.{ .routes = .{ ... } })`.
- Typed request captures for headers, query params, and path params (`zhttp.parse.*`).
- Endpoint-first routes (`pub fn call(comptime rctx, req)`).
- Composable middleware with compile-time `Info` capture merging.
- Built-in middleware: static files, CORS, logging, compression, timeout, ETag, request IDs, Expect handling, and security headers.
- Tight hot path with direct parse/write for HTTP/1.1.
- In-tree examples and benchmark harness.

## Quick Start

```bash
zig build examples
./zig-out/bin/zhttp-example-basic_server --port=8080
zig build examples-check
```

Minimal server:

```zig
const std = @import("std");
const zhttp = @import("zhttp");

const Hello = struct {
    pub const Info: zhttp.router.EndpointInfo = .{
        .query = struct {
            name: zhttp.parse.Optional(zhttp.parse.String),
        },
    };

    pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !rctx.Response([]const u8) {
        const name = req.queryParam(.name) orelse "world";
        const body = try std.fmt.allocPrint(req.allocator(), "hello {s}\n", .{name});
        return zhttp.Res.text(200, body);
    }
};

const App = zhttp.Server(.{
    .routes = .{
        zhttp.get("/hello", Hello),
    },
});

pub fn main(init: std.process.Init) !void {
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(8080) };
    var server = try App.init(init.gpa, init.io, addr, {});
    defer server.deinit();

    try server.run();
}
```

## Installation

Add as a dependency:

```bash
zig fetch --save git+https://github.com/SmallThingz/zhttp#main
```

`build.zig`:

```zig
const zhttp_dep = b.dependency("zhttp", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zhttp", zhttp_dep.module("zhttp"));
```

## Library API

- `zhttp.Server(.{ ... })` accepts `.Context`, `.middlewares`, `.operations`, `.routes`, `.config`, `.error_handler`, and `.not_found_handler`. `.error_handler` is a writer-based hook for user handler/middleware errors with signature `fn(*Server, *std.Io.Writer, comptime ErrorSet: type, err: ErrorSet) zhttp.router.Action`. Server parse/validation errors stay on the built-in bad-request path. If no not-found handler is provided, a built-in `404 not found` endpoint is used.
- Route helpers: `zhttp.get`, `post`, `put`, `delete`, `patch`, `head`, `options`, and `zhttp.route(...)` each take `(pattern, EndpointType)`.
- Endpoint types must expose `pub const Info: zhttp.router.EndpointInfo = .{ ... };` and `pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !rctx.Response(Body)`.
- Supported `Body` types are `[]const u8`, `[][]const u8`, `void`, and custom structs that expose `pub fn body(self, comptime rctx, req: rctx.TReadOnly(), cw) !void`.
- `EndpointInfo` fields: `.headers`, `.query`, `.path`, `.middlewares`, `.operations`.
- Optional endpoint upgrade hook: `pub fn upgrade(server, stream, r, w, line, res) void`. If present and `call` returns `101 Switching Protocols`, zhttp writes upgrade response and returns `zhttp.router.Action.upgraded`; the upgrade hook owns connection lifecycle.
- Standard middleware signatures are available at top-level as `zhttp.CorsSignature`.
- Header capture keys match case-insensitively, and `_` in field names matches `-` in incoming headers.
- If `Info.path` is omitted, path params default to strings.
- Route patterns support both segment params (`/users/{id}`) and trailing named globs (`/static/{*path}`).
- Typed request accessors include `req.header(...)`, `req.queryParam(...)`, `req.paramValue(...)`, `req.middlewareData(...)`, and `req.middlewareStatic(...)`.
- Request body helpers:
  - `req.bodyAll(max_bytes)` reads and caches the full request body for repeated use.
  - `req.bodyReader()` gives one-way streaming access to the request body.
  - `req.gpa()` returns the server allocator; memory taken from it must be freed manually.
- `rctx.TReadOnly()` produces the same request surface without middleware overrides. Use it from custom response body writers when you want direct access to the base request methods.

## Response Body Modes

- `[]const u8` uses `Content-Length` (single contiguous body).
- `[][]const u8` uses `Content-Length` (sum of segments, written via vectored I/O).
- `void` uses `Content-Length: 0`.
- Custom response body structs use `Transfer-Encoding: chunked`.

Chunked example shape:

```zig
const StreamBody = struct {
    pub fn body(_: @This(), comptime rctx: zhttp.ReqCtx, req: rctx.TReadOnly(), cw: *zhttp.response.ChunkedWriter) std.Io.Writer.Error!void {
        _ = req;
        try cw.writeAll("hello ");
        try cw.writeAll("world");
    }
};

pub fn call(comptime rctx: zhttp.ReqCtx, req: rctx.T()) !rctx.Response(StreamBody) {
    _ = req;
    return .{ .status = .ok, .body = .{} };
}
```

## Built-In Middleware

- `zhttp.middleware.Static`
- `zhttp.middleware.Cors`
- `zhttp.middleware.Origin`
- `zhttp.middleware.Logger`
- `zhttp.middleware.Compression`
- `zhttp.middleware.Timeout`
- `zhttp.middleware.Etag`
- `zhttp.middleware.Expect`
- `zhttp.middleware.RequestId`
- `zhttp.middleware.SecurityHeaders`

## Built-In Operations

- `zhttp.operations.Cors`
- `zhttp.operations.Static`

Both built-ins are route-tagged operations. Add operation types to endpoint
`Info.operations` and also register operation order in `Server(.{ .operations = .{...} })`.
`zhttp.operations.Cors` discovers matching middlewares by `zhttp.CorsSignature`,
and `zhttp.operations.Static` discovers middlewares that expose `operationRoutes()`.
Custom operation shape:
`pub fn operation(comptime opctx: zhttp.operations.OperationCtx, router: opctx.T()) void`.
Operations self-filter tagged routes via `opctx.filter(router)`.

See [`examples/builtin_middlewares.zig`](./examples/builtin_middlewares.zig) for the full built-in stack in one server.

## Examples

- `examples/basic_server.zig`
- `examples/middleware.zig`
- `examples/builtin_middlewares.zig`
- `examples/route_static_access.zig`
- `examples/echo_body.zig`
- `examples/fast_plaintext.zig`
- `examples/response_modes.zig`
- `examples/compression_negotiation.zig`
- `examples/custom_operation.zig`

## Performance Snapshots

Benchmark commands and modes are documented in [`benchmark/README.md`](./benchmark/README.md).

<!-- README_COMPARISON:START -->

Source: `benchmark/results/latest.json`

Config: host=`127.0.0.1` path=`/plaintext` conns=16 iters=200000 warmup=10000 full_request=true

| Target | req/s | ns/req | relative |
|---|---:|---:|---:|
| zhttp | 620300.93 | 1612.10 | 0.975x vs faf |
| faf | 635891.87 | 1572.60 | 1.025x vs zhttp |

No benchmark transport errors were reported.

Fairness notes: both targets use the same benchmark client settings (host/path/conns/iters/warmup/full_request), and fixed response bytes are discovered twice then pinned per target before timed runs
<!-- README_COMPARISON:END -->

## Build and Validation

```bash
zig build test
zig build test-flake -- --iterations=100 --jobs=1
zig build test-flake -- --iterations=200 --jobs=1 --retries=5 --test-filter="Server stop"
zig build examples
zig build examples-check
```

`test-flake` sweeps deterministic seeds, extracts failing test names, and prints both full-suite and single-test repro commands. It only flags a seed when reruns reproduce the failure. Add `--verbose` to dump full failing logs.
