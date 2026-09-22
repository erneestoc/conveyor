# Capacity

What one node and one database handle, from measured runs, and where the limits are.

## Measured

| Setup | Load | Result |
|---|---|---|
| One node (laptop, 8 cores), Postgres in Docker (2 vCPU) | 1,000 concurrent streams paced like real builds (1 event / 500 ms) | ack p50 75 ms, p99 146 ms, max 264 ms, 0 missing acks |
| Same | 200 streams replaying builds flat out | 13–15k events/s, ack p50 ≈ 0.3 s, p99 0.6–0.9 s; Postgres is the ceiling at 125 % of its 2 vCPU |
| Two clustered nodes (laptop), same Postgres | 20 streams flat out, connection drops, `kill -9` of a node every 70 s for 7 minutes | 48,039 builds, 5,016 events/s, ack p99 139 ms, 2,364 builds retried onto the other node, 0 missing acks, oracle green |
| Two `t4g.medium` nodes behind an NLB, RDS `db.t3.micro` | 20 streams paced (≈ 400 events/s) | database at 50–60 % CPU from the start, out of CPU credits after 40 minutes; not a usable shape |

Bazel's own rate: a build sends one event per action, test and target change; a large
CI build produces a few thousand events over minutes, so 1,000 concurrent builds is on
the order of a few thousand events per second, not tens of thousands.

## Where the cost goes

- **Acks** are bounded by the group-commit flush (`INGEST_WRITER_FLUSH_MS`, default a
  few tens of ms) plus PostgreSQL commit time. Ack latency tracks
  `conveyor_ingest_writer_flush_duration`.
- **PostgreSQL** does one statement per table per flush plus one fenced `UPDATE` per
  batch; the per-batch invocation update is the dominant cost (≈ 1 vCPU per 10k events/s
  of fixture replay). It must not be burstable under sustained ingest: a `t3`/`t4g` class
  spends credits at that rate and then runs at 10–20 % of a core.
- **Nodes** spend ≈ 0.9 MB per open stream plus ≈ 150 MB base and little CPU per event;
  the execution-log parser and profile summaries run on the same nodes (two parses at a
  time per node) and are the CPU spikes.
- **Storage** is ≈ 27 KB per small build compressed (row 9 KB, raw events 16 KB, log
  1 KB); real builds scale with targets, actions and log size. Raw segments are dropped
  after `RETENTION_RAW_DAYS`, everything else after `RETENTION_DAYS` (per project).

## Benchmark harness

`bench/run.sh` is the fixed measurement behind the speed and capacity plan (PLAN §24). It
hosts a production build of the server in one VM, drives `mix conveyor.loadgen` as a child
process against it, and samples both sides for the whole run:

| Number | How it is measured |
|---|---|
| events/s per app vCPU | events over the emulator's CPU time (`+sbwt none`, so busy-wait is off) and over the schedulers' own utilization |
| events/s per Postgres vCPU | events over the CPU time of every Postgres process (`ps`, native cluster from `bench/pg.sh`); `pg_stat_statements` execution time is recorded as the hardware-neutral twin |
| WAL bytes per event | `pg_stat_wal` delta over events |
| RSS per open stream | peak RSS during the run over the concurrent BES streams (paced profile) |

Also recorded per run: client-observed ack p50/p99, storage bytes per build and per table,
HOT ratio on `invocations`, round trips per flush (top-level statements) and nested
statements (foreign-key checks), the top statements by total time, rollbacks and redone
group commits, and the oracle over every generated invocation. Reports are JSON under
`bench/results/`; `--repeat 3` prints medians (run-to-run noise on a laptop is about
±10 %).

```sh
bench/pg.sh start                                 # native PostgreSQL 17 on 127.0.0.1:5441
bench/run.sh --label baseline --repeat 3          # 200 streams × 10k builds, flat out
bench/run.sh --label baseline --profile paced     # 1,000 streams paced like real builds
```

Every change in the plan is measured against the previous step with the same harness
before it is kept (ledger below). Two findings from the first runs reorder the plan:
native Postgres spends about 0.7 vCPU at 17.5k events/s (the earlier "1 vCPU per 10k
events/s" was Docker Desktop's VM), so on this hardware the node's own CPU (5.6 vCPU, 96 %
of it in the ingest workers) and its memory (10,000 finished workers lingering for 30 s
held 1.7 GB, 3.2 GB RSS at peak) are the ceilings, not the database; the Postgres items
(1, 2, 7) are worth their round trips and WAL on a networked database but do not move
throughput here.

## Speed plan ledger (PLAN §24)

Flat-out profile, 200 streams × 10,000 builds (438,750 events), medians of three runs,
16-core laptop, native PostgreSQL 17 on the same machine:

| Step | events/s | per app vCPU | per Postgres vCPU | WAL B/event | ack p50 / p99 ms | round trips | notes |
|---|---|---|---|---|---|---|---|
| 0 baseline (`8130675`) | 17,537 | 3,089 | 25,916 | 895 | 97 / 371 | 151k (18.5 per flush, 2,673 xact/s) | Postgres 0.67 vCPU, HOT 51 %, 35.6 KB/build |
| 1 fewer statements | 17,719 | 3,135 | 19–27k | 865 | 120 / 425 | 115k (14.0 per flush, 1,547 xact/s) | −24 % round trips, −42 % transactions, −3.5 % WAL; Postgres CPU within run noise (0.66–0.9 vCPU), planning time was the first version's hidden cost (unnamed statements planned per call, 4.2 s of 26 s) |
| 5 hibernate quiet workers | 17,670 | 3,190 | — | 866 | 107 / 400 | 115k | peak RSS 3.2 GB → 1.85 GB with 10,000 lingering workers; CPU unchanged |
| 4a scrubber prefilter | 20,040 | 5,843 | 27,964 | 810 | 49 / 217 | 105k (14.2 per flush) | node 5.5 → 3.4 vCPU: `eprof` of the absorb path showed 70 % in five regex passes over every string; a byte search now skips strings no pattern can match (148 → 36 µs per event in isolation); throughput is now generator-bound |

Paced profile (1,000 streams, one event per 500 ms, 1,500 builds), single runs:

| Step | events/s | ack p50 / p99 ms | round trips | RSS per stream | app vCPU | notes |
|---|---|---|---|---|---|---|
| 0 baseline | 990 | 69 / 284 | 141.6k (8.8 per flush) | 616 KB | 0.51 | 1,516 workers hold 378 MB of 472 MB process memory |
| 1 fewer statements | 990 | 68 / 275 | 96.1k (6.2 per flush) | 610 KB | 0.50 | −32 % round trips; acks unchanged |
| 5 hibernate quiet workers | 990 | 68 / 255 | 96.1k | 443 KB | 0.50 | workers 179 MB (was 378); flat-out peak RSS 1.85 GB with 10,000 lingering workers (was 3.2 GB), CPU unchanged |

## Starting points

| Concurrent builds | Nodes | PostgreSQL | Notes |
|---|---|---|---|
| up to 100 | 1 × 2 vCPU / 2 GB | 2 vCPU non-burstable (`db.m6g.large`), 100 GB gp3 | one box with Compose is enough for a team |
| up to 500 | 2 × 2 vCPU / 2 GB | 2 vCPU (`db.m6g.large`), 100 GB gp3 | balancer with cross-zone on |
| up to 2,000 or 20k events/s sustained | 3 × 4 vCPU / 4 GB | 4 vCPU (`db.m6g.xlarge`), IOPS headroom | watch flush duration and dead tuples |

`max_connections` must cover nodes × `POOL_SIZE` (default 40) plus 20. Measure with the
load generator against your own hardware before committing:
`mix conveyor.loadgen --hosts <host>:1985 [--tls] --api-key KEY --streams 200 --builds 2000 --verify`
([Scale and measurements](scale.md)).
