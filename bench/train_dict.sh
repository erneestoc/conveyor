#!/usr/bin/env bash
# Trains the zstd dictionary for raw BEP segments (PLAN §24 item 3) from the recorded
# fixtures, or from any directory of raw BEP files (one build per file, the
# --build_event_binary_file format). Needs the zstd CLI. A new dictionary must get a new
# id: frames record it, so every id ever written stays in priv/zstd/.
#
#   bench/train_dict.sh 1                     # priv/zstd/bep-1.dict from test/fixtures/bep
#   bench/train_dict.sh 2 /path/to/bep/files  # a bigger corpus, next id
set -euo pipefail
cd "$(dirname "$0")/.."
ID="${1:?dictionary id}"
SRC="${2:-test/fixtures/bep}"
WORK="$(mktemp -d)"
mix run --no-start -e '
[dir, src] = System.argv()
for f <- Path.wildcard(Path.join(src, "*.bep")) do
  frames = f |> File.read!() |> Conveyor.Bep.Fixture.frames()
  for {bytes, i} <- Enum.with_index(frames),
      do: File.write!(Path.join(dir, "#{Path.basename(f, ".bep")}-#{i}"), bytes)
end' -- "$WORK" "$SRC" 2>&1 | grep -v '^\[debug\]' || true
zstd --train -q --maxdict=65536 --dictID="$ID" -o "priv/zstd/bep-$ID.dict" "$WORK"/*
rm -rf "$WORK"
ls -la "priv/zstd/bep-$ID.dict"
