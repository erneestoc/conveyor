#!/usr/bin/env bash
# A native PostgreSQL 17 cluster for the benchmark harness (PLAN §24 item 0).
#
# Postgres in Docker Desktop is capped by the VM's 2 vCPUs and its CPU cannot be attributed
# per backend; a native cluster on the bench machine lets `mix conveyor.bench` read the CPU
# time of every Postgres process and removes the VM as the ceiling. Data lives under
# tmp/bench_pg (git-ignored). pg_stat_statements is preloaded for per-statement attribution.
#
#   bench/pg.sh init     # initdb + config (idempotent)
#   bench/pg.sh start    # start on 127.0.0.1:${BENCH_PG_PORT:-5441}
#   bench/pg.sh stop
#   bench/pg.sh status
#   bench/pg.sh psql [args]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-}"
for candidate in /opt/homebrew/opt/postgresql@17/bin /usr/lib/postgresql/17/bin /usr/local/opt/postgresql@17/bin; do
  [ -z "$PGBIN" ] && [ -x "$candidate/pg_ctl" ] && PGBIN="$candidate"
done
DATA="${BENCH_PG_DATA:-$ROOT/tmp/bench_pg/data}"
PORT="${BENCH_PG_PORT:-5441}"
LOG="$ROOT/tmp/bench_pg/postgres.log"

[ -n "$PGBIN" ] || { echo "PostgreSQL 17 binaries not found; brew install postgresql@17"; exit 1; }

init() {
  if [ -f "$DATA/PG_VERSION" ]; then echo "cluster exists at $DATA"; return; fi
  mkdir -p "$(dirname "$DATA")"
  "$PGBIN/initdb" -D "$DATA" -U postgres --auth=trust --encoding=UTF8 --locale=C >/dev/null
  cat >> "$DATA/postgresql.conf" <<CONF

# --- conveyor bench ---
listen_addresses = '127.0.0.1'
port = $PORT
max_connections = 200
shared_buffers = 1GB
effective_cache_size = 4GB
work_mem = 16MB
maintenance_work_mem = 256MB
wal_buffers = 64MB
max_wal_size = 4GB
checkpoint_completion_target = 0.9
random_page_cost = 1.1
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = 5000
pg_stat_statements.track = all
pg_stat_statements.track_planning = on
track_io_timing = on
track_wal_io_timing = on
log_min_messages = warning
log_checkpoints = off
autovacuum = on
CONF
  echo "initialized $DATA"
}

start() {
  mkdir -p "$(dirname "$LOG")"
  if "$PGBIN/pg_ctl" -D "$DATA" status >/dev/null 2>&1; then echo "already running"; return; fi
  "$PGBIN/pg_ctl" -D "$DATA" -l "$LOG" -w start >/dev/null
  echo "postgres on 127.0.0.1:$PORT (log: $LOG)"
}

stop() { "$PGBIN/pg_ctl" -D "$DATA" -m fast -w stop >/dev/null && echo "stopped"; }
status() { "$PGBIN/pg_ctl" -D "$DATA" status || true; }
psql_() { "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres "$@"; }

case "${1:-}" in
  init) init ;;
  start) init; start ;;
  stop) stop ;;
  status) status ;;
  psql) shift; psql_ "$@" ;;
  *) echo "usage: $0 init|start|stop|status|psql"; exit 1 ;;
esac
