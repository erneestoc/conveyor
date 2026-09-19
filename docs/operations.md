# Operations

## Health

- `GET /health/live`: the node is up.
- `GET /health/ready`: the database answers and the node is not draining. Balancers and
  orchestrators use this one; it turns 503 the moment a drain starts.

## Metrics

`GET /metrics` serves Prometheus text (protect it with `METRICS_TOKEN`). A Grafana
dashboard is in `deploy/grafana/conveyor.json`. The series that matter:

| Series | Alert when |
|---|---|
| `conveyor_ingest_ack_latency_us` (histogram) | p99 above 250 ms for 5 minutes: Bazel's end-of-build wait grows |
| `conveyor_ingest_writer_flush_duration` (histogram, ms) | p99 above 500 ms: PostgreSQL slow or contended |
| `conveyor_repo_query_queue_time` (histogram, ms) | p99 above 50 ms: pool too small or database saturated |
| `conveyor_ingest_batch_committed_events` (counter) | rate drops to zero while streams are open |
| `conveyor_ingest_streams_count`, `conveyor_ingest_workers_count` (gauges) | near `MAX_STREAMS_PER_KEY` times keys |
| `vm_memory_total`, `vm_system_counts_process_count` | memory growth without stream growth |

## Logs

Structured, one line per event, with the invocation id on every ingest message. Ingest
errors are rare by design: a stream failure is `UNAVAILABLE` (draining),
`RESOURCE_EXHAUSTED` (key limit), `UNAUTHENTICATED` (bad key) or `FAILED_PRECONDITION`
(out-of-order sequence), all of which Bazel handles by retrying or failing the upload,
never the build.

## Retention and storage

Nightly at 02:00 UTC builds older than `RETENTION_DAYS` are deleted in batches; hourly
the raw segment partitions older than `RETENTION_RAW_DAYS` are dropped and upcoming
partitions created; at 03:30 unpinned blobs older than `CAS_TTL_DAYS` are pruned. All
three are Oban jobs; failures retry and show in the logs.

Watch `pg_stat_user_tables` for dead tuples on `invocations` (autovacuum runs at 2 %) and
the size of the TOAST relation of `invocations` (`options` is the large column).

## Backups

PostgreSQL is the only state that matters; blobs are derivable (Bazel can re-upload
profiles) but cheap to keep. Standard base backups plus WAL archiving, or the managed
service's snapshots, are enough; Conveyor holds no local state beyond the blob directory
in disk mode.

## Rollouts

SIGTERM starts a drain: no new streams, readiness 503, up to `SHUTDOWN_DRAIN_SECONDS` for
open streams, then exit. Migrations run on boot and take the advisory lock Ecto uses, so
several nodes can boot at once. Balancer deregistration delay must exceed the drain.

## Runbook

- **Ack latency high, database fine**: check `conveyor_ingest_writer_flush_duration`
  and pool queue time. If flush is slow and Postgres CPU is high, the database is the
  bottleneck: bigger instance or more nodes will not help; fewer statements per commit
  would (see [scale](scale.md)).
- **Builds stuck in progress**: the client went away without finishing; the worker marks
  the build disconnected after `INGEST_IDLE_TIMEOUT_MS`.
- **`RESOURCE_EXHAUSTED` in Bazel**: the key's stream limit on that node; raise
  `MAX_STREAMS_PER_KEY` or add nodes.
- **Profiles missing**: the cache endpoint for the project is not reachable, or Bazel ran
  without a remote cache; see the build's Timeline tab message and
  [Cache endpoints](cache-endpoints.md).
- **Node will not join the cluster**: `RELEASE_COOKIE` differs, the distribution port is
  blocked, or `POD_IP`/`NODE_IP` is not routable; `bin/conveyor remote` then
  `Node.list()` to inspect.
