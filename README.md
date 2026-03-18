# zhttp
Low-latency HTTP/1.1 server primitives for Zig with comptime routing, typed captures, and composable middleware.

![Zig](https://img.shields.io/badge/Zig-0.16.0--dev-f7a41d?logo=zig&logoColor=111) ![Protocol](https://img.shields.io/badge/Protocol-HTTP%2F1.1-0f766e) ![Routing](https://img.shields.io/badge/Routing-comptime-1d4ed8) ![Focus](https://img.shields.io/badge/Focus-low--latency-111827)

## Features
- Comptime route registration via `zhttp.Server(.{ .routes = .{ ... } })`.
- Typed captures for headers, query strings, and path params using `zhttp.parse.*`.
- Flexible handler signatures: no-arg, request-only, context-only, or context + request.
- Global and per-route middleware composition with compile-time capture requirements.
- Built-in middleware for static files, CORS, logging, compression, timeouts, ETag, request IDs, and security headers.
- Request parsing and response writing tuned for a small, direct HTTP/1.1 hot path.
- Runnable examples plus a benchmark harness for in-process and external comparisons.

## Quick Start
```zig
const std = @import("std");
const zhttp = @import("zhttp");

fn hello(req: anytype) !zhttp.Res {
    const name = req.queryParam(.name) orelse "world";
    const body = try std.fmt.allocPrint(req.allocator(), "hello {s}\n", .{name});
    return zhttp.Res.text(200, body);
}

pub fn main(init: std.process.Init) !void {
    const App = zhttp.Server(.{
        .routes = .{
            zhttp.get("/hello", hello, .{
                .query = struct {
                    name: zhttp.parse.Optional(zhttp.parse.String),
                },
            }),
        },
    });

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(8080) };
    var server = try App.init(init.gpa, init.io, addr, {});
    defer server.deinit();

    try server.run();
}
```

Run the shipped examples:

```bash
zig build examples
./zig-out/bin/zhttp-example-basic_server --port=8080
zig build examples-check
```

## API Notes
- `Server(.{ ... })` accepts `.Context`, `.middlewares`, `.routes`, `.config`, and `.error_handler`.
- Route helpers: `zhttp.get`, `post`, `put`, `delete`, `patch`, `head`, `options`, or `zhttp.route(...)`.
- Route options: `.headers`, `.query`, `.params`, `.middlewares`.
- Header capture fields match case-insensitively, and `_` in field names matches `-` in incoming headers.
- If `.params` is omitted, path params default to strings.
- Request accessors are typed: `req.header(.host)`, `req.queryParam(.page)`, `req.paramValue(.id)`, `req.middlewareData(.name)`.
- Middleware `Needs` are merged into the route capture schema at comptime.

## Built-In Middleware
- `zhttp.middleware.Static`
- `zhttp.middleware.Cors`
- `zhttp.middleware.Logger`
- `zhttp.middleware.Compression`
- `zhttp.middleware.Timeout`
- `zhttp.middleware.Etag`
- `zhttp.middleware.RequestId`
- `zhttp.middleware.SecurityHeaders`

See [`examples/builtin_middlewares.zig`](./examples/builtin_middlewares.zig) for a complete stack using static file serving, request IDs, CORS, ETag, compression, timeout, and security headers together.

## Examples
- `examples/basic_server.zig`: typed query, header, and path param captures.
- `examples/middleware.zig`: route-scoped auth middleware with `Needs`.
- `examples/builtin_middlewares.zig`: built-in middleware stack.
- `examples/echo_body.zig`: request body reading with `req.bodyAll(...)`.
- `examples/fast_plaintext.zig`: stripped-down plaintext benchmark target.

## Benchmarking
Benchmark support lives under [`benchmark/`](./benchmark/).

```bash
zig build bench -Doptimize=ReleaseFast -- --mode=zhttp --conns=1 --iters=200000 --warmup=10000
zig run benchmark/run_zhttp_external.zig
BENCH_BIN=./zig-out/bin/zhttp-bench zig run benchmark/run_faf.zig
zig run benchmark/run_compare.zig
```

Additional benchmark notes and modes are documented in [`benchmark/README.md`](./benchmark/README.md).

## Architecture
- `src/router.zig`: comptime route definition, route merging, and middleware route injection.
- `src/request.zig`: request-line parsing, header parsing, capture decoding, and body helpers.
- `src/response.zig`: response serialization with `Content-Length`.
- `src/server.zig`: accept loop, keep-alive handling, dispatch, and error mapping.
- `src/middleware/`: built-in middleware implementations.

## Build / Validation
```bash
zig build test
zig build examples
zig build examples-check
zig build bench-server
```

## Current Scope
- HTTP/1.0 and HTTP/1.1 request parsing, with HTTP/1.1 response writing.
- Keep-alive connection handling and correct HEAD response body suppression.
- Responses currently always emit `Content-Length`; chunked responses are not implemented.
