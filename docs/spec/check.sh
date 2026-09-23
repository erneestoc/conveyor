#!/usr/bin/env bash
# Model-checks the ingest protocol with TLC: docs/spec/check.sh [Ingest:fixed Blobs:current ...]
set -euo pipefail
cd "$(dirname "$0")"
JAR="${TLA_TOOLS:-$HOME/tla/tla2tools.jar}"
[ -f "$JAR" ] || { echo "tla2tools.jar not found; set TLA_TOOLS"; exit 1; }
# Each entry is Module:config; the "fixed" configs must pass, the others document bugs.
configs=("$@"); [ ${#configs[@]} -gt 0 ] || configs=(Ingest:fixed Ingest:current Ingest:pre_m10 Blobs:fixed Blobs:current)
status=0
for entry in "${configs[@]}"; do
  m="${entry%%:*}"; c="${entry##*:}"
  echo "== $m $c"
  cp "${m}_$c.cfg" "$m.cfg"
  if java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -deadlock "$m.tla" > "tlc_${m}_$c.log" 2>&1; then
    grep -E 'Model checking completed|^[0-9]+ states generated' "tlc_${m}_$c.log"
  else
    grep -E 'Error:|violated' "tlc_${m}_$c.log" | head -3
    [ "$c" = fixed ] && status=1
  fi
  rm -f "$m.cfg"
done
rm -rf states
exit $status
