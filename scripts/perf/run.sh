#!/bin/sh
# Performance baseline: a 1M-character document, 100 operations each, in 3 fresh processes; prints each run's P50 / P95 (ms).
# Compare against scripts/perf/README.md before and after changes to the editor core.
set -e
cd "$(dirname "$0")/../.."
OUT=.build/perf
mkdir -p "$OUT"
node scripts/perf/gen.mjs "$OUT/big.md"
for run in 1 2 3; do
  swift scripts/webcheck.swift "$OUT/big.md" "$OUT/shot.png" light "$(cat scripts/perf/measure.js)" | sed -n 's/^JS result: /run '"$run"': /p'
done
