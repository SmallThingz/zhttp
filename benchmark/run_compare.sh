#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONNS="${CONNS:-16}"
ITERS="${ITERS:-200000}"
WARMUP="${WARMUP:-10000}"
FULL_REQUEST="${FULL_REQUEST:-1}"

echo "== zhttp =="
FULL_REQUEST="$FULL_REQUEST" CONNS="$CONNS" ITERS="$ITERS" WARMUP="$WARMUP" ./benchmark/run_zhttp_external.sh

echo
echo "== FaF =="
FULL_REQUEST="$FULL_REQUEST" CONNS="$CONNS" ITERS="$ITERS" WARMUP="$WARMUP" ./benchmark/run_faf.sh

