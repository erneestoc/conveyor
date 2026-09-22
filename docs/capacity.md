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
