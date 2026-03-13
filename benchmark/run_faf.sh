#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAF_DIR="${FAF_DIR:-/tmp/faf-example}"
FAF_CORE_DIR="${FAF_CORE_DIR:-/tmp/faf}"
PORT="${PORT:-8080}"
CONNS="${CONNS:-1}"
ITERS="${ITERS:-200000}"
WARMUP="${WARMUP:-10000}"
FULL_REQUEST="${FULL_REQUEST:-0}"
RUSTUP_BIN="${RUSTUP_BIN:-$HOME/.cargo/bin/rustup}"

if [[ "$PORT" != "8080" ]]; then
  echo "FaF example is hardcoded to port 8080 (PORT=$PORT requested)" >&2
  exit 2
fi

if [[ ! -d "$FAF_DIR/.git" ]]; then
  git clone https://github.com/errantmind/faf-example "$FAF_DIR"
fi

FAF_REV_FILE="$FAF_DIR/.faf_rev"
FAF_REV="$(
  (grep -F 'git+https://github.com/errantmind/faf.git#' "$FAF_DIR/Cargo.lock" 2>/dev/null || true) |
    head -n 1 |
    sed -E 's/.*#//; s/\".*$//'
)"
if [[ -z "${FAF_REV:-}" && -f "$FAF_REV_FILE" ]]; then
  FAF_REV="$(cat "$FAF_REV_FILE" | tr -d '\n' || true)"
fi
if [[ -z "${FAF_REV:-}" && -d "$FAF_CORE_DIR/.git" ]]; then
  FAF_REV="$(git -C "$FAF_CORE_DIR" rev-parse HEAD 2>/dev/null || true)"
fi
if [[ -z "${FAF_REV:-}" ]]; then
  echo "Failed to detect FaF git revision from $FAF_DIR/Cargo.lock" >&2
  exit 4
fi
echo -n "$FAF_REV" >"$FAF_REV_FILE"

if [[ ! -d "$FAF_CORE_DIR/.git" ]]; then
  git clone https://github.com/errantmind/faf "$FAF_CORE_DIR"
fi

pushd "$FAF_CORE_DIR" >/dev/null
  git fetch --all --tags >/dev/null 2>&1 || true
  git reset --hard -q
  git checkout -q "$FAF_REV"

  # Rust nightly changed the signature of `core::intrinsics::prefetch_read_data`.
  # Patch the pinned FaF revision so it compiles on newer toolchains.
  if grep -Eq "prefetch_read_data\\(.*,[[:space:]]*3\\)" src/util.rs; then
    sed -i -E 's/prefetch_read_data\((.*),[[:space:]]*3\)/prefetch_read_data::<u8, 3>(\1)/g' src/util.rs
  elif grep -Eq "prefetch_read_data\\(" src/util.rs && ! grep -Eq "prefetch_read_data::<" src/util.rs; then
    sed -i -E 's/prefetch_read_data\(/prefetch_read_data::<u8, 3>(/g' src/util.rs
  fi
popd >/dev/null

pushd "$FAF_DIR" >/dev/null
  # Ensure the example uses our pinned+patched FaF checkout.
  if grep -Fq 'faf = { git = "https://github.com/errantmind/faf.git" }' Cargo.toml; then
    sed -i -E "s|^faf = \\{ git = \\\"https://github\\.com/errantmind/faf\\.git\\\" \\}.*$|faf = { path = \\\"$FAF_CORE_DIR\\\" }|g" Cargo.toml
  fi

  # Newer Rust removed the `start` feature; the example already defines `main()`.
  if grep -Fq '#![feature(start, lang_items)]' src/main.rs; then
    sed -i -E '/^#!\[feature\(start, lang_items\)\]$/d' src/main.rs
  fi

  if [[ -x "$RUSTUP_BIN" ]]; then
    RUSTFLAGS="${RUSTFLAGS:--Ctarget-cpu=native}" "$RUSTUP_BIN" run nightly cargo build --release
  elif command -v rustup >/dev/null 2>&1; then
    RUSTFLAGS="${RUSTFLAGS:--Ctarget-cpu=native}" rustup run nightly cargo build --release
  else
    echo "rustup not found; FaF example requires nightly Rust." >&2
    echo "Install rustup, then: rustup toolchain install nightly" >&2
    exit 3
  fi
  ./target/release/faf-ex >/dev/null 2>&1 &
  FAF_PID="$!"
popd >/dev/null

cleanup() {
  kill "$FAF_PID" >/dev/null 2>&1 || true
  wait "$FAF_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 0.2

cd "$ROOT"
zig build bench -Doptimize=ReleaseFast -- \
  --mode=external \
  --host=127.0.0.1 \
  --port=8080 \
  --path=/plaintext \
  --conns="$CONNS" \
  --iters="$ITERS" \
  --warmup="$WARMUP" \
  $([[ "$FULL_REQUEST" != "0" ]] && echo "--full-request")
