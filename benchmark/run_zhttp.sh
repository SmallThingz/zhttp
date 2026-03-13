#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONNS="${CONNS:-1}"
ITERS="${ITERS:-200000}"
WARMUP="${WARMUP:-10000}"

exec zig build bench -Doptimize=ReleaseFast -- \
  --mode=zhttp \
  --conns="$CONNS" \
  --iters="$ITERS" \
  --warmup="$WARMUP"

