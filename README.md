# 🚀 zhttp

Low-latency HTTP/1.1 server primitives for Zig with comptime routing, typed captures, and composable middleware.

![zig](https://img.shields.io/badge/zig-0.16.0--dev-f7a41d?logo=zig&logoColor=111)
![protocol](https://img.shields.io/badge/protocol-http%2F1.1-0f766e)
![routing](https://img.shields.io/badge/routing-comptime-1d4ed8)
![core](https://img.shields.io/badge/core-pure%20zig-111827)

## ⚡ Features

- 🧭 **Comptime route table**: define routes once with `zhttp.Server(.{ .routes = .{ ... } })`.
- 🧠 **Typed request captures**: decode headers, query params, and path params with `zhttp.parse.*`.
- 🪝 **Flexible handlers**: support no-arg, request-only, context-only, or context + request handlers.
- 🧱 **Composable middleware**: mix global and per-route middleware with compile-time `Info` capture merging.
- 📦 **Built-in middleware**: static files, CORS, logging, compression, timeout, ETag, request IDs, and security headers.
- 🏎 **Tight hot path**: direct request parsing and response writing for low-overhead HTTP/1.1 servers.
- 🧪 **Runnable examples + benchmarks**: example servers and a small benchmark harness live in-tree.

## 🚀 Quick Start

```bash
zig build examples
./zig-out/bin/zhttp-example-basic_server --port=8080
zig build examples-check
```

Minimal server:

```zig
const std = @import("std");
const zhttp = @import("zhttp");

fn hello(comptime rctx: anytype, req: rctx.T()) !zhttp.Res {
    const name = req.queryParam(.name) orelse "world";
    const body = try std.fmt.allocPrint(req.allocator(), "hello {s}\n", .{name});
    _ = rctx;
    return zhttp.Res.text(200, body);
}

const App = zhttp.Server(.{
    .routes = .{
        zhttp.get("/hello", hello, .{
            .query = struct {
                name: zhttp.parse.Optional(zhttp.parse.String),
            },
        }),
    },
});

pub fn main(init: std.process.Init) !void {
    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(8080) };
    var server = try App.init(init.gpa, init.io, addr, {});
    defer server.deinit();

    try server.run();
}
```

## 📦 Installation

Add as a dependency:

```bash
zig fetch --save <git-or-tarball-url>
```

`build.zig`:

```zig
const zhttp_dep = b.dependency("zhttp", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zhttp", zhttp_dep.module("zhttp"));
```

## 🧩 Library API (At a Glance)

- `zhttp.Server(.{ ... })` accepts `.Context`, `.middlewares`, `.operations`, `.routes`, `.config`, `.error_handler`, `.not_found_handler`, and `.not_found_options`. `.error_handler` is a writer-based hook for user handler/middleware errors with signature `fn(*Server, *std.Io.Writer, comptime ErrorSet: type, err: ErrorSet) zhttp.router.Action`. Server parse/validation errors stay on the built-in bad-request path. If no not-found handler is provided, a built-in `404 not found` handler is used.
- Route helpers: `zhttp.get`, `post`, `put`, `delete`, `patch`, `head`, `options`, and `zhttp.route(...)`.
- Route options: `.headers`, `.query`, `.params`, `.middlewares`, `.upgrade_handler`.
- `.upgrade_handler` is route-local and optional (`null` by default). If present and the route returns `101 Switching Protocols`, zhttp writes the upgrade response and calls `fn(server, stream, r, w, line, res) void`; that path returns `zhttp.router.Action.upgraded` and the upgrade handler owns connection close/lifecycle.
- Header capture keys match case-insensitively, and `_` in field names matches `-` in incoming headers.
- If `.params` is omitted, path params default to strings.
- Typed request accessors include `req.header(...)`, `req.queryParam(...)`, `req.paramValue(...)`, and `req.middlewareData(...)`.

## 🧱 Built-In Middleware

- `zhttp.middleware.Static`
- `zhttp.middleware.Cors`
- `zhttp.middleware.Origin`
- `zhttp.middleware.Logger`
- `zhttp.middleware.Compression`
- `zhttp.middleware.Timeout`
- `zhttp.middleware.Etag`
- `zhttp.middleware.RequestId`
- `zhttp.middleware.SecurityHeaders`

## ⚙️ Built-In Operations

- `zhttp.operations.Cors(MiddlewareType)`
- `zhttp.operations.Static(MiddlewareType)`

See [`examples/builtin_middlewares.zig`](./examples/builtin_middlewares.zig) for the full built-in stack in one server.

## 📎 Examples

- `examples/basic_server.zig`
- `examples/middleware.zig`
- `examples/builtin_middlewares.zig`
- `examples/echo_body.zig`
- `examples/fast_plaintext.zig`

## 🏁 Benchmarking

Benchmark support lives under [`benchmark/`](./benchmark/).

```bash
zig build bench -Doptimize=ReleaseFast -- --mode=zhttp --conns=1 --iters=200000 --warmup=10000
zig run benchmark/run_zhttp_external.zig
BENCH_BIN=./zig-out/bin/zhttp-bench zig run benchmark/run_faf.zig
zig run benchmark/run_compare.zig
```

For the full benchmark modes and notes, see [`benchmark/README.md`](./benchmark/README.md).

## 🧪 Build and Validation

```bash
zig build test
zig build examples
zig build examples-check
zig build bench-server
```

## ⚠️ Current Scope

`zhttp` is intentionally focused on a small HTTP/1.1 server core.

- Request parsing covers HTTP/1.0 and HTTP/1.1.
- Responses are written as HTTP/1.1 with `Content-Length`.
- Keep-alive and HEAD response semantics are handled.
- Chunked responses are not implemented yet.
