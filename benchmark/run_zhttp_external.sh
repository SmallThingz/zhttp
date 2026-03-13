#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-8081}"
CONNS="${CONNS:-1}"
ITERS="${ITERS:-200000}"
WARMUP="${WARMUP:-10000}"
FULL_REQUEST="${FULL_REQUEST:-0}"

zig build -Doptimize=ReleaseFast

./zig-out/bin/zhttp-bench-server --port="$PORT" >/dev/null 2>&1 &
SRV_PID="$!"

cleanup() {
  kill "$SRV_PID" >/dev/null 2>&1 || true
  wait "$SRV_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 0.2

exec zig build bench -Doptimize=ReleaseFast -- \
  --mode=external \
  --host=127.0.0.1 \
  --port="$PORT" \
  --path=/plaintext \
  --conns="$CONNS" \
  --iters="$ITERS" \
  --warmup="$WARMUP" \
  $([[ "$FULL_REQUEST" != "0" ]] && echo "--full-request")
