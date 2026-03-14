#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PERF_DATA="${PERF_DATA:-perf.zhttp.server.data}"
PERF_TOP_N="${PERF_TOP_N:-20}"
FULL_REPORT="${FULL_REPORT:-0}"
PERF_TREE="${PERF_TREE:-1}"
PERF_PERCENT="${PERF_PERCENT:-1}"
PERF_TREE_DEPTH="${PERF_TREE_DEPTH:-6}"
PERF_COMPACT="${PERF_COMPACT:-1}"
PERF_UNICODE="${PERF_UNICODE:-1}"
PERF_COLOR="${PERF_COLOR:-1}"
FLAMEGRAPH="${FLAMEGRAPH:-0}"
FLAMEGRAPH_OUT="${FLAMEGRAPH_OUT:-perf.svg}"
CONNS="${CONNS:-1}"
ITERS="${ITERS:-200000}"
WARMUP="${WARMUP:-10000}"
PATH_NAME="${PATH_NAME:-/plaintext}"
MODE="${MODE:-zhttp}"
QUIET="${QUIET:-0}"
FULL_REQUEST="${FULL_REQUEST:-0}"
FIXED_BYTES="${FIXED_BYTES:-}"

ZIG_CACHE_DIR="${ZIG_CACHE_DIR:-$ROOT/.zig-cache}"
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-cache-global}"

BIN="$ROOT/zig-out/bin/zhttp-bench"

needs_build() {
  [[ ! -x "$BIN" ]] && return 0
  [[ "$ROOT/benchmark/bench.zig" -nt "$BIN" ]] && return 0
  find "$ROOT/src" -name '*.zig' -newer "$BIN" -print -quit | grep -q . && return 0
  return 1
}

if needs_build; then
  printf "\033[1;34m== build zhttp-bench ==\033[0m\n"
  zig build-exe \
    -OReleaseFast \
    --dep zhttp \
    -Mroot="$ROOT/benchmark/bench.zig" \
    -Mzhttp="$ROOT/src/root.zig" \
    --cache-dir "$ZIG_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
    --name zhttp-bench \
    -femit-bin="$BIN"
else
  printf "\033[1;34m== build zhttp-bench: up-to-date ==\033[0m\n"
fi

printf "\033[1;34m\n== config ==\033[0m mode=%s path=%s conns=%s iters=%s warmup=%s full=%s fixed=%s\n" \
  "$MODE" "$PATH_NAME" "$CONNS" "$ITERS" "$WARMUP" "$FULL_REQUEST" "${FIXED_BYTES:-auto}"
printf "perf_data=%s top_n=%s tree=%s min%%=%s full_report=%s\n" "$PERF_DATA" "$PERF_TOP_N" "$PERF_TREE" "$PERF_PERCENT" "$FULL_REPORT"
printf "tree_depth=%s compact=%s unicode=%s color=%s flamegraph=%s\n" "$PERF_TREE_DEPTH" "$PERF_COMPACT" "$PERF_UNICODE" "$PERF_COLOR" "$FLAMEGRAPH"

cmd=("$BIN"
  --mode="$MODE"
  --conns="$CONNS"
  --iters="$ITERS"
  --warmup="$WARMUP"
  --path="$PATH_NAME"
)

if [[ "$QUIET" == "1" ]]; then
  cmd+=(--quiet)
fi
if [[ "$FULL_REQUEST" == "1" ]]; then
  cmd+=(--full-request)
fi
if [[ -n "$FIXED_BYTES" ]]; then
  cmd+=(--fixed-bytes="$FIXED_BYTES")
fi

printf "\033[1;34m\n== perf record ==\033[0m\ncmd: \033[1;35m"
printf "%q " "${cmd[@]}"
printf "\033[0m\n\n"
perf record -g -o "$PERF_DATA" -- "${cmd[@]}"

if [[ "$PERF_TREE" == "1" ]]; then
  printf "\033[1;34m\n== perf report (tree, >=%s%%) ==\033[0m\n" "$PERF_PERCENT"
  perf report --stdio -i "$PERF_DATA" \
    --call-graph=graph,${PERF_PERCENT},${PERF_TREE_DEPTH},caller,function,percent \
    --sort=symbol --percent-limit "$PERF_PERCENT" --stdio-color=never 2>&1 | \
    if [[ "$PERF_COMPACT" == "1" ]]; then
      if [[ "$PERF_UNICODE" == "1" ]]; then
        awk -v color="$PERF_COLOR" '
          BEGIN { use_color = (color == 1 || color == "1") }
          
          function get_color(pct_str,    num, p, r, g, r_idx, g_idx) {
            num = pct_str + 0
            if (num <= 0) return "\033[0m"
            
            p = num / 5.0
            if (p > 1.0) p = 1.0
            
            if (p <= 0.5) {
              r = int(p * 2.0 * 255)
              g = 255
            } else {
              r = 255
              g = int((1.0 - (p - 0.5) * 2.0) * 255)
            }
            
            r_idx = int((r + 25) / 51)
            g_idx = int((g + 25) / 51)
            if (r_idx > 5) r_idx = 5
            if (g_idx > 5) g_idx = 5
            
            return sprintf("\033[1;38;5;%dm", 16 + 36 * r_idx + 6 * g_idx)
          }

          /^#/ || $0 == "" { next }
          /^[ \t]*[0-9]+\.[0-9]+%[ \t]+[0-9]/ { next } # Skip flat overhead summary lines
          /^[ \t|]+$/ { next } # Skip purely vertical connecting lines

          {
            line = $0
            if (match(line, /[0-9]+\.[0-9]+%/)) {
              raw_prefix = substr(line, 1, RSTART - 1)
              pct = substr(line, RSTART, RLENGTH)
              rest = substr(line, RSTART + RLENGTH)
            } else if (match(line, /[^ \t|`\\-]/)) {
              raw_prefix = substr(line, 1, RSTART - 1)
              pct = ""
              rest = substr(line, RSTART)
            } else {
              next
            }

            # 1. Strip base indentation but preserve visual hierarchy
            match(raw_prefix, /[^ \t]/)
            if (RSTART > 0) {
              prefix = "  " substr(raw_prefix, RSTART)
            } else {
              prefix = raw_prefix
            }

            # 2. Extract and replace end tree token
            end_char = ""
            if (sub(/\|--$/, "", prefix)) end_char = "┣"
            else if (sub(/---$/, "", prefix)) end_char = "┗"
            else if (sub(/.[-]-$/, "", prefix)) end_char = "┗"
            else if (sub(/--$/, "", prefix)) end_char = "┗"

            # 3. Compress the structural blocks proportionally
            gsub(/\|[ \t]{6,18}/, "┃ ", prefix)
            gsub(/[ \t]{7,19}/, "  ", prefix)

            prefix = prefix end_char

            # 4. Clean up trailing symbol syntax 
            sub(/^[ \t]+/, "", rest)
            sub(/^\[[^\]]+\][ \t]+/, "", rest) 
            sub(/^[ \t]+/, "", rest)

            if (use_color) {
              c_pct = (pct != "") ? get_color(pct) : ""
              if (pct != "") {
                printf "\033[90m%s\033[0m%s%s\033[0m %s\n", prefix, c_pct, pct, rest
              } else {
                printf "\033[90m%s\033[0m %s\n", prefix, rest
              }
            } else {
              if (pct != "") {
                printf "%s%s %s\n", prefix, pct, rest
              } else {
                printf "%s %s\n", prefix, rest
              }
            }
          }
        '
      else
        awk -v color="$PERF_COLOR" '
          BEGIN { use_color = (color == 1 || color == "1") }
          
          function get_color(pct_str,    num, p, r, g, r_idx, g_idx) {
            num = pct_str + 0
            if (num <= 0) return "\033[0m"
            
            p = num / 5.0
            if (p > 1.0) p = 1.0
            
            if (p <= 0.5) {
              r = int(p * 2.0 * 255)
              g = 255
            } else {
              r = 255
              g = int((1.0 - (p - 0.5) * 2.0) * 255)
            }
            
            r_idx = int((r + 25) / 51)
            g_idx = int((g + 25) / 51)
            if (r_idx > 5) r_idx = 5
            if (g_idx > 5) g_idx = 5
            
            return sprintf("\033[1;38;5;%dm", 16 + 36 * r_idx + 6 * g_idx)
          }

          /^#/ || $0 == "" { next }
          /^[ \t]*[0-9]+\.[0-9]+%[ \t]+[0-9]/ { next }
          /^[ \t|]+$/ { next }

          {
            line = $0
            if (match(line, /[0-9]+\.[0-9]+%/)) {
              raw_prefix = substr(line, 1, RSTART - 1)
              pct = substr(line, RSTART, RLENGTH)
              rest = substr(line, RSTART + RLENGTH)
            } else if (match(line, /[^ \t|`\\-]/)) {
              raw_prefix = substr(line, 1, RSTART - 1)
              pct = ""
              rest = substr(line, RSTART)
            } else {
              next
            }

            match(raw_prefix, /[^ \t]/)
            if (RSTART > 0) {
              prefix = "  " substr(raw_prefix, RSTART)
            } else {
              prefix = raw_prefix
            }

            end_char = ""
            if (sub(/\|--$/, "", prefix)) end_char = "|-"
            else if (sub(/---$/, "", prefix)) end_char = "`-"
            else if (sub(/.[-]-$/, "", prefix)) end_char = "`-"
            else if (sub(/--$/, "", prefix)) end_char = "`-"

            gsub(/\|[ \t]{6,18}/, "| ", prefix)
            gsub(/[ \t]{7,19}/, "  ", prefix)

            prefix = prefix end_char

            sub(/^[ \t]+/, "", rest)
            sub(/^\[[^\]]+\][ \t]+/, "", rest)
            sub(/^[ \t]+/, "", rest)

            if (use_color) {
              c_pct = (pct != "") ? get_color(pct) : ""
              if (pct != "") {
                printf "\033[90m%s\033[0m%s%s\033[0m %s\n", prefix, c_pct, pct, rest
              } else {
                printf "\033[90m%s\033[0m %s\n", prefix, rest
              }
            } else {
              if (pct != "") {
                printf "%s%s %s\n", prefix, pct, rest
              } else {
                printf "%s %s\n", prefix, rest
              }
            }
          }
        '
      fi
    else
      sed -E '/^#/d;/^$/d'
    fi
else
  printf "\033[1;34m\n== perf report (top %s) ==\033[0m\n" "$PERF_TOP_N"
  perf report --stdio -i "$PERF_DATA" --call-graph=graph --sort=symbol --percent-limit "$PERF_PERCENT" --no-children 2>&1 | \
    awk -v n="$PERF_TOP_N" -v color="$PERF_COLOR" '
      BEGIN { printed = 0; use_color = (color == 1 || color == "1") }
      
      function get_color(pct_str,    num, p, r, g, r_idx, g_idx) {
        num = pct_str + 0
        if (num <= 0) return "\033[0m"
        p = num / 5.0
        if (p > 1.0) p = 1.0
        if (p <= 0.5) { r = int(p * 2.0 * 255); g = 255 } 
        else { r = 255; g = int((1.0 - (p - 0.5) * 2.0) * 255) }
        r_idx = int((r + 25) / 51); g_idx = int((g + 25) / 51)
        if (r_idx > 5) r_idx = 5; if (g_idx > 5) g_idx = 5
        return sprintf("\033[1;38;5;%dm", 16 + 36 * r_idx + 6 * g_idx)
      }

      /^ *Overhead/ {
        print "overhead  symbol"
        next
      }
      $0 ~ /^ *[0-9]/ {
        overhead = $1
        symbol = ""
        for (i = 3; i <= NF; i++) symbol = symbol (symbol=="" ? "" : " ") $i
        
        if (use_color) {
          c_pct = get_color(overhead)
          printf "%s%7s\033[0m  %s\n", c_pct, overhead, symbol
        } else {
          printf "%7s  %s\n", overhead, symbol
        }
        
        printed++
        if (printed >= n) exit
      }
      END {
        if (printed == 0) exit 3
      }
    ' || {
      printf "perf report had no parsable rows; showing full report.\n"
      perf report --stdio -i "$PERF_DATA" --call-graph=graph --sort=symbol --percent-limit "$PERF_PERCENT" --no-children 2>&1
    }
fi

if [[ "$FULL_REPORT" == "1" ]]; then
  printf "\033[1;34m\n== perf report (full) ==\033[0m\n"
  perf report --stdio -i "$PERF_DATA" --call-graph=graph --sort=symbol --percent-limit "$PERF_PERCENT"
fi

if [[ "$FLAMEGRAPH" == "1" ]]; then
  printf "\033[1;34m\n== flamegraph ==\033[0m\n"
  if command -v stackcollapse-perf.pl >/dev/null 2>&1 && command -v flamegraph.pl >/dev/null 2>&1; then
    perf script -i "$PERF_DATA" | stackcollapse-perf.pl | flamegraph.pl > "$FLAMEGRAPH_OUT"
    printf "wrote \033[1;36m%s\033[0m\n" "$FLAMEGRAPH_OUT"
  else
    printf "\033[1;31mmissing stackcollapse-perf.pl or flamegraph.pl in PATH\033[0m\n"
  fi
fi
