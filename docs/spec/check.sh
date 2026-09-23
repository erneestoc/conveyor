#!/usr/bin/env bash
# Model-checks the ingest protocol with TLC: docs/spec/check.sh [fixed|current|pre_m10 ...]
set -euo pipefail
cd "$(dirname "$0")"
JAR="${TLA_TOOLS:-$HOME/tla/tla2tools.jar}"
[ -f "$JAR" ] || { echo "tla2tools.jar not found; set TLA_TOOLS"; exit 1; }
configs=("$@"); [ ${#configs[@]} -gt 0 ] || configs=(fixed current pre_m10)
status=0
for c in "${configs[@]}"; do
  echo "== $c"
  cp "Ingest_$c.cfg" Ingest.cfg
  if java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers auto -deadlock Ingest.tla > "tlc_$c.log" 2>&1; then
    grep -E 'Model checking completed|^[0-9]+ states generated' "tlc_$c.log"
  else
    grep -E 'Error:|violated' "tlc_$c.log" | head -3
    [ "$c" = fixed ] && status=1
  fi
  rm -f Ingest.cfg
done
rm -rf states
exit $status
