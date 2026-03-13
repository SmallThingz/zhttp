# Benchmarks

This folder contains a tiny, allocation-free hot-loop benchmark client:

- It opens one or more TCP connections.
- It repeatedly writes a pre-rendered HTTP/1.1 request string (minimal request by default).
- It discards a fixed number of bytes per response (no HTTP parsing in the hot loop).

## zhttp (in-process)

```sh
zig build bench -Doptimize=ReleaseFast -- --mode=zhttp --conns=1 --iters=200000 --warmup=10000
```

## zhttp (external)

Runs `zhttp-bench-server` and benchmarks it via the same client in `--mode=external`:

```sh
./benchmark/run_zhttp_external.sh
```

## FaF (external)

FaF is benchmarked against the `faf-example` app (`/plaintext` on port `8080`).
`./benchmark/run_faf.sh` clones both `faf-example` and `faf` into `/tmp/`, pins FaF to the revision in
`Cargo.lock`, and applies a tiny compatibility patch (for newer Rust nightly intrinsics) before building.

```sh
./benchmark/run_faf.sh
```

## Compare (external)

Runs both servers with the same benchmark client settings (defaults: `FULL_REQUEST=1`, `CONNS=16`):

```sh
./benchmark/run_compare.sh
```

To point at an already running server:

```sh
zig build bench -Doptimize=ReleaseFast -- --mode=external --host=127.0.0.1 --port=8080 --path=/plaintext
```

Notes:
- `--host` is currently expected to be an IPv4 literal.
- If `--fixed-bytes` is not provided, the benchmark auto-discovers `Content-Length` once (outside the hot loop).
- Use `--full-request` to send `Host:` and `Connection:` headers (default is the minimal `GET ...\r\n\r\n` request).
- For the helper scripts, set `FULL_REQUEST=1` to pass `--full-request`:
  - `FULL_REQUEST=1 ./benchmark/run_zhttp_external.sh`
  - `FULL_REQUEST=1 ./benchmark/run_faf.sh`
