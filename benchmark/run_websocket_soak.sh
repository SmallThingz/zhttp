#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-19090}"
CLIENTS="${CLIENTS:-200}"
DURATION_MS="${DURATION_MS:-30000}"
MESSAGES_PER_CONN="${MESSAGES_PER_CONN:-32}"

zig build soak-websocket-server >/dev/null

./zig-out/bin/zhttp-websocket-soak-server --port="${PORT}" &
SERVER_PID=$!
cleanup() {
  kill "${SERVER_PID}" >/dev/null 2>&1 || true
  wait "${SERVER_PID}" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1

bun benchmark/websocket_soak_bun.ts \
  --url="ws://127.0.0.1:${PORT}/ws" \
  --clients="${CLIENTS}" \
  --duration-ms="${DURATION_MS}" \
  --messages-per-conn="${MESSAGES_PER_CONN}"
