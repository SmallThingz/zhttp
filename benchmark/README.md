# Benchmarks

This folder contains a tiny, allocation-free hot-loop benchmark client:

- It opens one or more TCP connections.
- It repeatedly writes a pre-rendered HTTP/1.1 request string (minimal request by default).
- It discards a fixed number of bytes per response (no HTTP parsing in the hot loop).

## zhttp (in-process)

```sh
zig build bench -Doptimize=ReleaseFast -- --mode=zhttp --conns=1 --iters=100000 --warmup=10000
```

Convenience runner (environment-driven defaults):

```sh
CONNS=1 ITERS=100000 WARMUP=10000 zig run benchmark/run_zhttp.zig
```

## zhttp (external)

Runs `zhttp-bench-server` and benchmarks it via the same client in `--mode=external`:

```sh
zig run benchmark/run_zhttp_external.zig
# or
zig build bench
```

`run_zhttp_external` writes `benchmark/results/bench_latest.json` and
`benchmark/results/bench_latest.md`, and refreshes the README fetch section.

## FaF (external)

FaF is benchmarked against the `faf-example` app (`/plaintext` on port `8080`).
`zig run benchmark/run_faf.zig` clones both `faf-example` and `faf` into `.zig-cache/faf-example` and
`.zig-cache/faf`, pins FaF to the revision in `Cargo.lock`, and applies a tiny compatibility patch
(for newer Rust nightly intrinsics) before building. It expects `zhttp-bench` to be available;
set `BENCH_BIN` to a built bench binary path or build it first.

```sh
BENCH_BIN=./zig-out/bin/zhttp-bench zig run benchmark/run_faf.zig
```

## Compare (external)

Runs both servers with the same benchmark client settings (defaults: `FULL_REQUEST=1`, `CONNS=16`, `REUSE=1`):
- identical `host/path/conns/iters/warmup/full_request/reuse`
- fixed response bytes discovered twice per target and pinned for the timed run

```sh
zig run benchmark/run_compare.zig
# or
zig build bench-compare
```

`run_compare` writes:
- `benchmark/results/latest.json`
- `benchmark/results/latest.md`

and refreshes README comparison/fetch sections.

To point at an already running server:

```sh
zig build bench -Doptimize=ReleaseFast -- --mode=external --host=127.0.0.1 --port=8080 --path=/plaintext
```

Notes:
- `--host` is currently expected to be an IPv4 literal.
- If `--fixed-bytes` is not provided, the benchmark auto-discovers `Content-Length` once (outside the hot loop).
- `run_zhttp_external.zig` and `run_faf.zig` both validate response size stability by discovering fixed bytes twice before timing.
- Use `--full-request` to send `Host:` and `Connection:` headers (default is the minimal `GET ...\r\n\r\n` request).
- `--reuse=1` (default) reuses one keep-alive connection per worker; use `--reuse=0` / `--no-reuse` to reconnect every request.
- For zhttp server config, prefer `.temp_worker_spawn = .polling` for keep-alive-heavy (`--reuse=1`) traffic and `.temp_worker_spawn = .signaled` for reconnect-heavy (`--reuse=0`) traffic.
- For the helper scripts, set `FULL_REQUEST=1` to pass `--full-request`:
  - `FULL_REQUEST=1 zig run benchmark/run_zhttp_external.zig`
  - `FULL_REQUEST=1 zig run benchmark/run_faf.zig`
- For helper scripts, set `REUSE=0` to disable reuse:
  - `REUSE=0 zig run benchmark/run_zhttp_external.zig`
  - `REUSE=0 zig run benchmark/run_faf.zig`

## perf helper

`run_perf.zig` replaces the old shell helper and records/report profiles by driving `zhttp-bench`:

```sh
MODE=zhttp CONNS=1 ITERS=100000 WARMUP=10000 zig run benchmark/run_perf.zig
```
