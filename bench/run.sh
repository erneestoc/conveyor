#!/usr/bin/env bash
# Runs `mix conveyor.bench` with the environment that makes runs comparable (PLAN §24 item 0):
# a prod build of the server in this VM, the native bench Postgres from bench/pg.sh, no
# scheduler busy-wait (so CPU time is work), ports that do not collide with a dev server,
# and ingest auth off so the generator needs no key.
#
#   bench/run.sh --label baseline                       # flat-out profile, 200 streams × 10k builds
#   bench/run.sh --label baseline --profile paced       # 1,000 paced streams
#   bench/run.sh --label fewer-statements --repeat 3    # median of three
#
# Any INGEST_* variable in the environment is passed through (see config/runtime.exs).
set -euo pipefail
cd "$(dirname "$0")/.."

export BENCH_PG_PORT="${BENCH_PG_PORT:-5441}"
bench/pg.sh start >/dev/null

export MIX_ENV=prod
export DATABASE_URL="${DATABASE_URL:-ecto://postgres@127.0.0.1:${BENCH_PG_PORT}/conveyor_bench}"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-bench-secret-key-base-bench-secret-key-base-bench-secret-key-base-0000}"
export PHX_SERVER=true
export PHX_HOST=localhost
export PORT="${PORT:-4199}"
export GRPC_PORT="${GRPC_PORT:-1999}"
export BES_INGEST_AUTH=none
export BLOB_DIR="$PWD/tmp/blobs_bench"
export POOL_SIZE="${POOL_SIZE:-40}"
export ERL_FLAGS="+sbwt none +sbwtdcpu none +sbwtdio none"
export CLUSTER_STRATEGY=none

bench/pg.sh psql -Atc "SELECT 1 FROM pg_database WHERE datname = 'conveyor_bench'" | grep -q 1 \
  || bench/pg.sh psql -Atc "CREATE DATABASE conveyor_bench" >/dev/null
mix ecto.migrate --quiet
exec mix conveyor.bench "$@"
