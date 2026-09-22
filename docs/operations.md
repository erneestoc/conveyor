# Operations

## Health

- `GET /health/live`: the node is up.
- `GET /health/ready`: the database answers and the node is not draining. Balancers and
  orchestrators use this one; it turns 503 the moment a drain starts.

## Metrics

`GET /metrics` serves Prometheus text (set `METRICS_TOKEN` for the scraper; without it only an admin session may read it). A Grafana
dashboard is in `deploy/grafana/conveyor.json`. The series that matter:

| Series | Alert when |
|---|---|
| `conveyor_ingest_ack_latency_us` (histogram) | p99 above 250 ms for 5 minutes: Bazel's end-of-build wait grows |
| `conveyor_ingest_writer_flush_duration` (histogram, ms) | p99 above 500 ms: PostgreSQL slow or contended |
| `conveyor_repo_query_queue_time` (histogram, ms) | p99 above 50 ms: pool too small or database saturated |
| `conveyor_ingest_batch_committed_events` (counter) | rate drops to zero while streams are open |
| `conveyor_ingest_streams_count`, `conveyor_ingest_workers_count` (gauges) | near `MAX_STREAMS_PER_KEY` times keys |
| `conveyor_ingest_fenced_count` (counter) | any increase that repeats: two nodes wrote one invocation (balancer or lifecycle problem) |
| `conveyor_oban_jobs_count{queue,state}`, `conveyor_oban_oldest_available_seconds{queue}` (gauges) | oldest waiting job older than 10 minutes: the queue is not draining |
| `conveyor_blobs_errors_count{op}` (counter) | any increase: blob store credentials, bucket policy or disk |
| `vm_memory_total`, `vm_system_counts_process_count` | memory growth without stream growth |

Ready-made rules for these are in `deploy/prometheus/alerts.yml`.

### Stuck jobs

Execution-log parsing, profile fetches and maintenance run as Oban jobs (`oban_jobs`).
A node that dies mid-job leaves it `executing`; the Lifeline plugin moves it back to
`available` after 15 minutes (or discards it when its attempts are used up). Two rules
learned on the AWS trial:

- Rescue with Oban's API, never by editing rows: `Oban.retry_all_jobs(query)` or
  `Oban.retry_job/1` raise `max_attempts` as needed. A row set to `available` by hand with
  `attempt = max_attempts` is never fetched again, and looks exactly like a stalled queue.
- Lifeline is naive: a job that legitimately runs longer than 15 minutes is "rescued" while
  still running, runs twice and burns an attempt each time. Long jobs must finish or fail
  inside their `timeout/1` (the parser's is 10 minutes).

## Logs

Structured, one line per event, with the invocation id on every ingest message. Ingest
errors are rare by design: a stream failure is `UNAVAILABLE` (draining),
`RESOURCE_EXHAUSTED` (key limit), `UNAUTHENTICATED` (bad key) or `FAILED_PRECONDITION`
(out-of-order sequence), all of which Bazel handles by retrying or failing the upload,
never the build.

## Retention and storage

Nightly at 02:00 UTC builds older than `RETENTION_DAYS` (or the project's own retention,
set in Settings) are deleted in batches per project; hourly the raw segment partitions
older than `RETENTION_RAW_DAYS` are dropped and upcoming partitions created; at 03:30
unpinned blobs older than `CAS_TTL_DAYS` and blobs no remaining build references (their
builds were retained away) are pruned. All three are Oban jobs; failures retry and show
in the logs.

Blobs are stored per project under the project's key prefix (`<S3_PREFIX>/<prefix>/` in
S3, `<BLOB_DIR>/<prefix>/` on disk; the prefix is the slug unless changed in Settings), so
one project's data can be listed, given a bucket lifecycle rule or removed on its own.
Projects never share blobs. Blobs written before 0.2 sit in the old flat layout and stay
readable; new writes go under the prefix.

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
