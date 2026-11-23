#!/usr/bin/env bash
# Duplicate work from the event stream at the scale of PLAN §27.9, adapted (PLAN §28.5):
# projects of one cache group, recorded builds with `--build_event_publish_all_actions`
# replayed concurrently through the gRPC ingest of one prod-mode node against the native
# bench Postgres (bench/pg.sh), keys merged by the node's jobs as builds end.
#
#   bench/stream_scale.sh --label first                    # 60 projects, 300 builds
#   bench/stream_scale.sh --label small --projects 10 --builds 40
#
# The database `conveyor_stream_scale` is dropped and created again on every run (drop
# it afterwards: `bench/pg.sh psql -c 'DROP DATABASE conveyor_stream_scale'`). What is
# measured and how exactness is checked: the top of bench/stream_scale.exs. Results go to
# bench/results/stream_scale-<label>.json. Environment: CONCURRENCY (streams at once,
# default 40), SEED.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=run PROJECTS=60 BUILDS=300
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --projects) PROJECTS="$2"; shift 2 ;;
    --builds) BUILDS="$2"; shift 2 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done

export BENCH_PG_PORT="${BENCH_PG_PORT:-5441}"
bench/pg.sh start >/dev/null
DB=conveyor_stream_scale
bench/pg.sh psql -Atc "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null
bench/pg.sh psql -Atc "CREATE DATABASE $DB" >/dev/null

export MIX_ENV=prod
export DATABASE_URL="ecto://postgres@127.0.0.1:${BENCH_PG_PORT}/$DB"
export SECRET_KEY_BASE="bench-secret-key-base-bench-secret-key-base-bench-secret-key-base-0000"
export PHX_HOST=localhost
export BES_INGEST_AUTH=api_key
export BLOB_DIR="$PWD/tmp/blobs_stream_scale"
export POOL_SIZE="${POOL_SIZE:-20}"
export ERL_FLAGS="+sbwt none +sbwtdcpu none +sbwtdio none"
export CLUSTER_STRATEGY=none
rm -rf "$BLOB_DIR"
mkdir -p tmp/stream_scale

mix compile >/dev/null
mix ecto.migrate --quiet

PHX_SERVER=true PORT=4199 GRPC_PORT=1999 mix phx.server > tmp/stream_scale/node.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
  curl -fs -o /dev/null http://localhost:4199/health/ready && break
  sleep 1
done
curl -fs -o /dev/null http://localhost:4199/health/ready || { echo "the node did not start; see tmp/stream_scale/node.log"; exit 1; }

LABEL="$LABEL" GRPC=localhost:1999 PROJECTS="$PROJECTS" BUILDS="$BUILDS" \
  mix run --no-start bench/stream_scale.exs
