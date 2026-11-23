#!/usr/bin/env bash
# The 360-project case of the duplicate-work analysis (PLAN §27.9): one cache group, a
# project per app, every build uploading an execution log, parsed by the real `parse`
# queue of one or two prod-mode nodes against the native bench Postgres (bench/pg.sh).
#
#   bench/rbe_scale.sh --label first                      # 360 projects, 2,000 builds, 1 node
#   bench/rbe_scale.sh --label two-nodes --nodes 2
#   bench/rbe_scale.sh --label small --projects 40 --builds 200
#
# The database `conveyor_rbe_scale` is dropped and created again on every run. The model,
# what is measured and how exactness is checked are described at the top of
# bench/rbe_scale.exs; results go to bench/results/rbe_scale-<label>.json. Environment
# passed through to the driver: SPAWNS_MIN, SPAWNS_MAX, SHARED_POOL, WAVE, HOURS, SEED,
# UPLOADERS, ANALYSIS_ONLY (1 = the projects keep only what the metrics need), RETAIN_AFTER_DAYS
# (how far the retention clock is moved for the after-retention sizes, default 4). Needs about 1.5 GB of disk per million spawns.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL=run NODES=1 PROJECTS=360 BUILDS=2000
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --nodes) NODES="$2"; shift 2 ;;
    --projects) PROJECTS="$2"; shift 2 ;;
    --builds) BUILDS="$2"; shift 2 ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
done

export BENCH_PG_PORT="${BENCH_PG_PORT:-5441}"
bench/pg.sh start >/dev/null
DB=conveyor_rbe_scale
bench/pg.sh psql -Atc "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null
bench/pg.sh psql -Atc "CREATE DATABASE $DB" >/dev/null

export MIX_ENV=prod
export DATABASE_URL="ecto://postgres@127.0.0.1:${BENCH_PG_PORT}/$DB"
export SECRET_KEY_BASE="bench-secret-key-base-bench-secret-key-base-bench-secret-key-base-0000"
export PHX_HOST=localhost
export BES_INGEST_AUTH=none
export BLOB_DIR="$PWD/tmp/blobs_rbe_scale"
export POOL_SIZE="${POOL_SIZE:-20}"
export ERL_FLAGS="+sbwt none +sbwtdcpu none +sbwtdio none"
export CLUSTER_STRATEGY=none
rm -rf "$BLOB_DIR"
mkdir -p tmp/rbe_scale

mix compile >/dev/null
mix ecto.migrate --quiet

PIDS=()
URLS=()
cleanup() { for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

for n in $(seq 1 "$NODES"); do
  port=$((4199 - n + 1)); grpc=$((1999 - n + 1))
  PHX_SERVER=true PORT=$port GRPC_PORT=$grpc mix phx.server > "tmp/rbe_scale/node-$n.log" 2>&1 &
  PIDS+=($!)
  URLS+=("http://localhost:$port")
done

for url in "${URLS[@]}"; do
  for _ in $(seq 1 60); do
    curl -fs -o /dev/null "$url/health/ready" && break
    sleep 1
  done
  curl -fs -o /dev/null "$url/health/ready" || { echo "node at $url did not start; see tmp/rbe_scale/"; exit 1; }
done

NODES_CSV=$(IFS=,; echo "${URLS[*]}")
LABEL="$LABEL" NODES="$NODES_CSV" PROJECTS="$PROJECTS" BUILDS="$BUILDS" \
  mix run --no-start bench/rbe_scale.exs
