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
  after `RETENTION_RAW_DAYS`, everything else after `RETENTION_DAYS` (per project). With
  the raw archive on (`RAW_ARCHIVE_ENABLED`), raw events and logs leave PostgreSQL a day
  after the build and live in the blob store as one object each, so the database holds
  about `RAW_ARCHIVE_AFTER_HOURS/24 + 1` days of raw data whatever the raw retention is
  (measured per build in the ledger below).

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
| 6 dashboards from rollups | — | — | — | — | — | — | read side, see the table below: 2.2 s → 0.5 s per dashboard load with 100k builds in range |
| 3 BEP zstd dictionary | 19,726 | 5,806 | 23,589 | 731 | 47 / 213 | 107k | storage per build 33.1 → 29.7 KB (event segments 135 → 84 MB for the same 10k builds), WAL −10 %; CPU unchanged. Dictionary `priv/zstd/bep-1.dict` trained on the fixtures (`bench/train_dict.sh`); held out, a 15-event segment compresses 8.5× instead of 4.1×. Postgres exec time spreads 45–80k events per exec-second between runs depending on whether a checkpoint lands mid-run |

| raw write-behind (`1b986fa`), A/B against `333da0b` | 19,551 (baseline 19,115) | 5,802 (5,793) | 28,846 (21,497) | 713 (711) | 49 / 242 (54 / 250) | 106k | ingest unchanged by the archive's migration (four unindexed columns, an index on `inserted_at`): same harness on both sides, the baseline run from a worktree with the migration rolled back; Postgres per vCPU spreads 21–30k on both sides with checkpoint timing; oracle 10,000/10,000 and 0 missing acks on all six runs |

**Raw archive on the bench database** (10,000 flat-out builds from the run above, disk
blob store, `RawArchive.archive/2` over every build at concurrency 8, then the hourly
partition drop with its guard, then `Verify.check/2` on every build):

| | database per build | event segments | log segments | invocations | blobs table | blob store |
|---|---|---|---|---|---|---|
| before | 31.4 KB | 8.4 KB | 0.7 KB | 10.1 KB | — | — |
| archived, partitions still there | 31.8 KB | 8.4 KB | 0.7 KB | 10.1 KB | 0.35 KB | 6.6 KB |
| after the partition drop | **22.7 KB (−28 %)** | 0 | 0 | 10.1 KB | 0.35 KB | 6.6 KB |

10,000 archived in 10.6 s (944 builds/s), 10,000/10,000 verified from the blobs after the
drop. One object per build compresses the whole event stream at once: 6.6 KB against
8.4 KB of per-flush segments. The replayed fixtures repeat their log text, so logs
deduplicated to 8 objects here; real logs are one object per build. What stays in
PostgreSQL per build is the row and its normalized tables (targets, tests, actions,
metrics), which `RETENTION_DAYS` governs; raw data now costs the blob store's price
($0.023/GB-month on S3) for as long as it is kept, plus two PUTs per build.

**Execution-log storage** (2026-10-01; `bench/spawn_bench.exs`: three real logs
from the trial, 1,706, 1,404 and 1,969 spawns, each stored as 30 builds of one project,
native PostgreSQL 17 on the laptop):

| | Lists copied per spawn (`ead53f5^`) | Lists once per project and digest (`ead53f5`) |
|---|---|---|
| 90 builds, 152,370 spawns | 10,524 MB, **117 MB per build** | 367 MB (spawns 143 MB + 3,653 lists 224 MB), **4.1 MB per build** |
| store | 838 ms per build | 123 ms per build |
| explain (1,706 rows) / one diff | 44 ms / 1 ms | 23 ms / 1 ms |
| delete the spawns of 45 builds | 45 s | 26 ms |
| prune 1,706 orphan lists | — | 416 ms |
| migration over the baseline table (80,130 spawns, 10 GB) | — | 1.5 s (the sort touches only digests; blobs are detoasted for the 1,947 winners) |

Concurrency (`bench/spawn_load.exs`, same logs): 8 writers storing builds as fast as
they can for 120 s while one task expires two random builds' spawns every 200 ms and
another prunes orphan lists with no grace period, the worst case `SpawnInputs.tla`
models: **1,084 builds stored (9.0 per second, about 15,000 spawns/s), 1,074 expired,
5,700 lists pruned, 0 dangling references, 0 orphans left.** The first run of this test
deadlocked three writers: logs sharing lists in a different spawn order locked the same
rows in a different order. Stores now upsert their lists sorted by digest, one global lock
order (`ExecLog.input_rows/3`, pinned by a test).

The trial's real data: before the migration 48,030 spawns, 10,109 distinct lists, 1,220 MB
of a 1,518 MB database; the migration moved 13,527 lists (per project) into 307 MB in 69 s
on the `db.t3.micro`, and after `VACUUM FULL spawns` (6 s) the spawns table is 45 MB and
the database 650 MB. The nightly job then expired a project's 71 builds older than its
7-day spawn retention in 11 s. What remains per spawn is about 900 bytes of row (label, output
path, outputs JSON, timings, digests, indexes), so spawn retention (`RETENTION_SPAWN_DAYS`,
30 by default) bounds the table at days × builds × spawns × 1 KB plus one copy of each
distinct list in the window.

## Fleet test on AWS (2026-10-01)

Three `t4g.large` nodes behind the NLB, `db.m6g.xlarge`, generators as Fargate tasks
running the Conveyor image with a corpus of 120 **real builds** (117–1,043 events each,
median 603, decompressed from the trial's archived event streams; `bench/fleet.sh`,
`deploy/trial/loadgen.tf`), one event per 500 ms per stream, so a build lasts about five
minutes, through the balancer over TLS. One API key per generator task (the per-key limits
are per node). Server-side numbers from CloudWatch and an oracle over 300 sampled builds
per window (`Conveyor.Ingest.Verify`).

| Level | Generators | Server side | Client side |
|---|---|---|---|
| 1,000 concurrent builds | 4 tasks × 250 streams, 15 min | 2,897 builds in the window, oracle 300/300; RDS CPU avg 14 % (max 20 %), nodes avg 25 % | the two surviving tasks: 2,101/2,110 builds, ack **p50 81 ms, p99 ≤ 116 ms**, 0 missing acks; 9 failures were the per-key limit (200 streams per node per key) rejecting a single-key fleet; two tasks died out of memory at 250 streams |
| 5,000 concurrent builds, **rolling deploy** at minute 2 | 40 tasks × 125, 15 min | 9,444 builds and 2.82 M events in the window, oracle 300/300; RDS CPU avg 22 % (max 32 %), 500 write IOPS; nodes avg 36 %; all three new nodes healthy | the generators never resumed the 4,549 streams the drained nodes dropped: every acknowledged event is stored, but the test client's reconnection through the NLB does not work like Bazel's, so the client-side numbers for this level are not usable |
| 10,000 concurrent builds | 80 tasks × 125 (16 min to launch) | a node held about 2,000 open streams in 958 MB with a run queue of 4; nodes avg 68 % CPU, RDS avg 19 % (max 45 %), up to 739 write IOPS; **no server errors** | connections dropped continuously and the generator opened new builds instead of resuming: 26,873 abandoned against 683 finished when stopped. Not a server limit; the generator's connection handling through the NLB over TLS is |

What the fleet test established: through a balancer over TLS, acknowledgement latency at
1,000 real concurrent builds is the same as on a laptop (p99 about 115 ms); a
`db.m6g.xlarge` sits below a quarter of a core at 5,000 builds (the laptop ratio of 0.7
vCPU per 20k events/s holds on RDS); three 2-vCPU nodes carry 5,000 streams at a third of
their CPU and about 6,000 at two thirds; a rolling deploy under 5,000 streams kept the
server consistent. What it did not establish: a client-side number above 1,000 streams,
because the generator (not Bazel) failed over badly through the NLB and ran out of memory
at 250 streams per task. Fixed since: the client gives a silent stream up after
`--ack-timeout-ms` with events outstanding and resumes the invocation from its last
acknowledged event on a fresh connection (`Conveyor.Bep.Replay`, `--retries`); tasks run
125 streams each. The rerun of levels 2 and 3 is below.

### Rerun with the fixed generator (2026-10-01, same shape)

Same fleet shape, image `363696a` (then `00ba4a3`/`a0780cd`, see below), one new key per
task, 125 streams per task, builds paced at one event per 500 ms.

| Run | Generators | Server side | Client side |
|---|---|---|---|
| smoke, 50 concurrent builds | 1 task, 2 min | — | 54/54 builds, 0 missing acks, ack p50 79 ms / p99 101 ms / max 320 ms |
| **5,000 concurrent builds, rolling deploy at minute 2 — first attempt, server failure** | 40 tasks × 125, 15 min | the three replacement nodes were each **killed out of memory two to four times** (BEAM at 7.6 GB on an 8 GB `t4g.large`) while absorbing the drained nodes' resumed streams: one process, the `Phoenix.PubSub` forwarder that receives every other node's broadcasts, held 191k queued messages and 5.9 GB; the writers queued 130k batches behind it. Every acknowledged event was stored (0 missing acks) | 4,728/14,161 builds ok, 9,433 failed after 5 retries, ack p99 17 min: the generator kept a silent stream open as long as its paced sender was active (fixed in `a0780cd`, the deadline follows the oldest unacknowledged event) |

| 5,000 concurrent builds, rolling deploy at minute 2 — second attempt, image `00ba4a3` (watched broadcasts only) | 40 tasks × 125, 15 min | **no OOM kill, no restart**, nodes at 2.6–4 GB; but one writer shard per node sat on 130k–344k queued batches: every fenced batch (routine while the balancer moves streams) made the writer redo its 256-batch group one transaction at a time, and with two shards on two vCPUs the node never caught up (nodes avg 60 % CPU, max 92 %; RDS avg 33 %, 614 write IOPS, 129 connections) | 13,608/22,026 builds ok, 8,418 failed (ack timeouts after 5 retries, a few FAILED_PRECONDITION rejects from stale workers whose batch sat in the backlog), 0 missing acks, ack p50 127 ms / p90 326 ms / p99 15 s |

| 5,000 concurrent builds, rolling deploy at minute 2 — third attempt, image `be12ae2` (fenced batches evict only their invocation from the group) and 8 writer shards per node | 40 tasks × 125, 15 min | no OOM, no restart, but **both tiers saturated**: nodes avg 68 % / max 95 % CPU (both vCPUs), 4.4–4.6 GB; RDS avg 68 % / max 95 % CPU, 1,423 write IOPS avg (2,410 max); 2k–6k fenced commits and ~1k FAILED_PRECONDITION rejects per node. A fence now costs the group's rows twice (rollback + retry), so at several fences per second the eight shards pushed the database harder than the two-shard per-batch fallback had | 7,418/21,651 builds ok, 14,233 failed, 0 missing acks, ack p50 193 ms / p90 4.2 s / p99 25.7 s |

| **5,000 concurrent builds, rolling deploy at minute 2 — fourth attempt, three `t4g.xlarge` (4 vCPU / 16 GB), image `be12ae2`, 8 writer shards** | 40 tasks × 125, 15 min | **clean**: 20,903 builds and 10.3 M events in the window, 0 unfinished, oracle 300/300 (day-aware); nodes avg 54 % CPU (max 85 %), 1.5–2.6 GB; RDS avg 58 % CPU (max 78 %), 1,000 write IOPS avg (1,554 max), 129 connections; **0 fenced commits and 0 rejects** on the replacement nodes after the deploy. One replacement node's BEAM was OOM-killed three times (15.7 GB) in the minutes after it joined, with no stream errors: it was the node serving a browser that had the load-test builds list open, so every one of the project's 5,000 workers sent it a full summary (options included, tens of KB) four times a second. List messages are slim and coalesced since `CHANGELOG` "watched builds list"; the ingest side was unaffected (0 failed builds) | **20,903/20,903 builds ok, 0 failed, 5,237 resumed across the deploy, 0 missing acks; ack p50 105 ms / p90 194 ms / p99 519 ms / max 3.2 s** |

What the four attempts say: three 2-vCPU nodes do **not** carry 5,000 paced real builds
through a rolling deploy. The earlier "a third of their CPU" figure came from a run in
which most generator streams had silently died. At about 1,700 streams per node the two
vCPUs are at 85 % before the deploy; when the balancer then moves a node's streams, the
survivors' ack latency crosses the clients' 30 s timeout, clients resend, the resends fence
the stale workers' batches, and every tier does extra work until the clients give up. The
PubSub and writer fixes removed two amplifiers (a 6 GB queue and a 256× fallback) but not
the ceiling; three 4-vCPU nodes carry the same load through the same deploy with every build completing and p99 half a second. Size by open streams: about 500 per vCPU with room for a deploy.

The root cause is a cluster-wide broadcast per build per 250 ms (summary, detail and
log chunks for every live stream) that no one was watching. Since `00ba4a3`, pages
subscribe through `Conveyor.Watch` and a worker broadcasts a topic only while some
process in the cluster watches it (a `:pg` group per topic), so an unwatched stream costs
no cross-node traffic at all.

Paced profile (1,000 streams, one event per 500 ms, 1,500 builds), single runs:

| Step | events/s | ack p50 / p99 ms | round trips | RSS per stream | app vCPU | notes |
|---|---|---|---|---|---|---|
| 0 baseline | 990 | 69 / 284 | 141.6k (8.8 per flush) | 616 KB | 0.51 | 1,516 workers hold 378 MB of 472 MB process memory |
| 1 fewer statements | 990 | 68 / 275 | 96.1k (6.2 per flush) | 610 KB | 0.50 | −32 % round trips; acks unchanged |

Read side (item 6), dev database with 100k builds in range, Docker Postgres, one dashboard
load = 17 panels:

| Step | 7d | 30d | 90d | notes |
|---|---|---|---|---|
| exact panels | 1.90 s | 2.11 s | 2.20 s | `actions_by_mnemonic` 0.8–1.0 s, `phases_over_time` 0.3 s, `queue_trend` 0.15 s (jsonb aggregation over every build) |
| 6 hourly rollups | 0.54 s | 0.53 s | 0.51 s | summary, series, phases, queue, mnemonics read `invocation_rollups` (674 project-hours, 704 kB; backfill 4.3 s); a window check of 65–80 ms per page load repairs stale or missing hours, edges are computed exactly; the rest is the still-exact panels (`target_regressions` 0.1 s, `by_user`, `slowest_builds`) |

On the trial (one `t4g.medium`, RDS `db.t3.micro`, 3.6k builds and 48k spawns): a dashboard
view took 3.3–4.3 s before the panels were loaded once per view (the disconnected render
and the connected mount each loaded everything), the window's rows were computed once per
page, and the spawn reports (cache by mnemonic, cache-missing targets, remote bytes) came
from the rollups. After: first byte 0.34–0.41 s, then 1.5 s of panels over the socket of
which `non_hermetic` alone is 1.1 s (a parallel hash self-join over every spawn, the next
report to precompute at parse time); every rolled panel is under 15 ms.
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
