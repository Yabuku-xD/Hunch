#!/usr/bin/env bash
# S4 / I10 perf gate (v3 plan §C + §D). Exit 0 only when every measured target holds:
#   1. U13 grep gate: no per-keystroke localization lookups or List/LazyVStack/NSTableView in keystroke-path files.
#      ANIM_GREP gate: no perpetual or implicit animations (repeatForever, TimelineView, timers, display links,
#      `.animation(x)` without `value:`) anywhere in Sources/BetterSpotlight.
#   2. App `--measure` (optimized build with the DEBUG measurement hooks compiled in, own scratch path):
#      panel_show p95 ≤ 14 ms, first_results p95 ≤ 33 ms, commit p95 ≤ 12 ms, idle CPU ≤ 0.1 %,
#      hover idle CPU ≤ 0.05 %, hover footprint Δ ≤ 1 MB.
#   3. `spot-bench --incremental` (§C scenarios, required targets; the bench exits 1 on a miss).
# Extra args go to spot-bench --incremental (e.g. --files 20000 --runs 1 --idle-seconds 10).
# Never touches xcode-select; runs on the Command Line Tools.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
OUT=${TMPDIR:-/tmp}/betterspotlight/perf-gate
mkdir -p "$OUT"
fail=0
miss() { echo "PERF_MISS $*"; fail=1; }
# --measure-only: steps 1–2 (the verify chain runs it from make-app.sh; the bench runs on its own).
MEASURE_ONLY=0
if [[ ${1:-} == --measure-only ]]; then MEASURE_ONLY=1; shift; fi

# 1. U13 grep gate.
KEYSTROKE_FILES=(Sources/BetterSpotlight/SearchView.swift Sources/BetterSpotlight/Rows.swift
                 Sources/BetterSpotlight/SearchModel.swift)
hits=$(grep -nE 'String\(localized:|Bundle\.[a-z]*\.?localizedString|NSLocalizedString|\bList\(|LazyVStack|NSTableView' \
         "${KEYSTROKE_FILES[@]}" | grep -vE '^\S+:[0-9]+:\s*//' || true)
if [[ -n $hits ]]; then echo "$hits"; miss "U13 keystroke-path grep gate"; else echo "U13_GREP_OK"; fi

# 1b. ANIM_GREP gate (motion rules, v4 spec M3): comment lines excluded. Measure.swift is the DEBUG-only frame
# counter of --measure (its CADisplayLink is the instrument), so it is exempt. An `.animation(x)` that breaks its
# line before `value:` counts as explicit when the next line carries the `value:`.
ANIM_FILES=$(find Sources/BetterSpotlight -name '*.swift' ! -name Measure.swift | sort)
anim=$( { grep -nE 'repeatForever|TimelineView|Timer\.scheduledTimer|Timer\.publish|CADisplayLink' $ANIM_FILES /dev/null \
            | grep -vE '^\S+:[0-9]+:\s*//'
          awk 'FNR == 1 && prev != "" { print prev; prev = "" }
               prev != "" { if ($0 !~ /value:/) print prev; prev = "" }
               /^[[:space:]]*\/\// { next }
               /\.animation\([^,)]*\)$/ { prev = FILENAME ":" FNR ":" $0 }
               END { if (prev != "") print prev }' $ANIM_FILES 2>/dev/null; } || true)
if [[ -n $anim ]]; then echo "$anim"; miss "ANIM_GREP gate"; else echo "ANIM_GREP_OK"; fi

# 2. App --measure on an optimized build.
if swift build -c release --scratch-path .build/perf --product BetterSpotlight -Xswiftc -DDEBUG >"$OUT/build-app.log" 2>&1; then
  # Two launches: the first absorbs the index catch-up of whatever the build just wrote under ~/Downloads (it
  # competes with the panel for CPU); the second is the measured one.
  for pass in warmup measure; do
    .build/perf/release/BetterSpotlight --measure >"$OUT/$pass.log" 2>"$OUT/$pass.err" &
    pid=$!
    for _ in $(seq 1 150); do grep -q "summary hover_footprint_delta_mb" "$OUT/$pass.log" && break; sleep 1; done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  done
  grep '^summary' "$OUT/measure.log"
  p95() { grep "^summary $1 " "$OUT/measure.log" | sed -E 's/.*p95=([0-9.]+).*/\1/'; }
  p50() { grep "^summary $1 " "$OUT/measure.log" | sed -E 's/.*p50=([0-9.]+).*/\1/'; }
  # Flat key=value lines, like spot-bench's, so a filtered verify log keeps them.
  for k in panel_show first_results commit; do
    echo "${k}_p50_ms=$(p50 ${k}_ms)"; echo "${k}_p95_ms=$(p95 ${k}_ms)"
  done
  echo "$(grep -m1 '^cold_first_results_ms=' "$OUT/measure.log")"
  echo "idle_cpu_pct=$(grep '^summary idle_cpu_pct=' "$OUT/measure.log" | sed -E 's/.*idle_cpu_pct=([0-9.]+).*/\1/')"
  check() { # name value target
    if [[ -z $2 ]]; then miss "$1 not reported"; return; fi
    awk -v v="$2" -v t="$3" 'BEGIN { exit !(v <= t) }' && echo "PERF_OK $1=$2 <= $3" || miss "$1=$2 > $3"
  }
  check panel_show_p95_ms "$(p95 panel_show_ms)" 14
  check first_results_p95_ms "$(p95 first_results_ms)" 33
  check commit_p95_ms "$(p95 commit_ms)" 12
  check idle_cpu_pct "$(grep '^summary idle_cpu_pct=' "$OUT/measure.log" | sed -E 's/.*idle_cpu_pct=([0-9.]+).*/\1/')" 0.1
  # U15: a row hovered with the pointer still, and the footprint after repeated hovers.
  flat() { grep -m1 "^summary $1=" "$OUT/measure.log" | sed -E "s/.*$1=(-?[0-9.]+).*/\1/"; }
  check hover_idle_cpu_pct "$(flat hover_idle_cpu_pct)" 0.05
  check hover_footprint_delta_mb "$(flat hover_footprint_delta_mb)" 1
else
  tail -20 "$OUT/build-app.log"; miss "app build"
fi

# 3. spot-bench --incremental (§C).
if (( MEASURE_ONLY )); then
  :
elif swift build -c release --product spot-bench >"$OUT/build-bench.log" 2>&1; then
  .build/release/spot-bench --incremental "$@" 2> >(grep -v '^\.\.\.' >"$OUT/incremental.err") | tee "$OUT/incremental.log" \
    | grep -E '^incremental_gate|_strict_ok=|^inc_s[0-9]_(wall_ms|files_read|extractions|chunks_embedded)='
  [[ ${PIPESTATUS[0]} -eq 0 ]] || { grep MISS "$OUT/incremental.err"; miss "spot-bench --incremental"; }
else
  tail -20 "$OUT/build-bench.log"; miss "spot-bench build"
fi

(( fail == 0 )) && echo "PERF_GATE=PASS" || echo "PERF_GATE=FAIL"
exit "$fail"
