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
| `conveyor_ingest_writer_backlog_oldest_ms{shard}` (gauge), `conveyor_ingest_writer_flush_wait` (histogram, ms) | oldest above 5,000 ms for a minute, or wait p99 above 5,000 ms: commits are not keeping up; batches expire at `INGEST_WRITER_DEADLINE_MS` (20 s). See "Commit pressure" below |
| `conveyor_ingest_writer_backlog_batches{shard}`, `conveyor_ingest_writer_backlog_bytes{shard}` (gauges) | growing over several scrapes: the same, earlier |
| `conveyor_ingest_writer_expired_count` (counter) | any increase: batches waited past their deadline and their streams failed; clients are resending |
| `conveyor_ingest_writer_group_failed_count{kind}` (counter) | `unavailable` or `data` at all; `contention` repeating; `fenced` follows `conveyor_ingest_fenced_count` |
| `conveyor_oban_jobs_count{queue,state}`, `conveyor_oban_oldest_available_seconds{queue}` (gauges) | oldest waiting job older than 10 minutes: the queue is not draining |
| `conveyor_blobs_errors_count{op}` (counter) | any increase: blob store credentials, bucket policy or disk |
| `conveyor_raw_log_put_failed_count`, `conveyor_raw_log_sweep_failed_count` (counters) | any increase: the blob store refuses raw-log writes or deletes (`RAW_LOG=blob`); see "Raw log (blob mode)" below |
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

Execution-log parses run two at a time on the `parse` queue (`default` carries profile
fetches and summaries, `maintenance` the nightly jobs); `conveyor_oban_jobs_count` and
`conveyor_oban_oldest_available_seconds` carry a label per queue.

## Logs

Structured, one line per event, with the invocation id on every ingest message. Ingest
errors are rare by design: a stream failure is `UNAVAILABLE` (draining),
`RESOURCE_EXHAUSTED` (key limit), `UNAUTHENTICATED` (bad key) or `FAILED_PRECONDITION`
(out-of-order sequence), all of which Bazel handles by retrying or failing the upload,
never the build.

## Retention and storage

Nightly at 02:00 UTC builds older than `RETENTION_DAYS` (or the project's own retention,
set in Settings) are deleted in batches per project, execution-log spawns older than
`RETENTION_SPAWN_DAYS` (per project too) are deleted and their builds marked `expired`
on the Actions tab, and the input lists nothing references any more are pruned; hourly the raw segment partitions
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

**After upgrading to 0.2.4** (input lists moved out of `spawns`): the migration copies the
lists into `spawn_inputs` and drops the column, but PostgreSQL keeps a dropped column's
data until the table is rewritten. Run `VACUUM FULL spawns` once, at a quiet moment (it
locks the table for the rewrite: 6 s for the trial's 1.2 GB table on its smallest instance) to get
the space back; until then the table stays its old size.

Every ten minutes `SweepStale` marks builds `disconnected` that are still `in_progress`
but whose row has not changed for two idle windows (`INGEST_IDLE_TIMEOUT_MS`, 10 minutes
by default): a node died under them and Bazel gave up. A client that comes back later
resumes the build as after an idle timeout.

### Splitting a project

Builds land in the project of the API key that sent them. To split an existing project
(everything went to `default` before teams had keys), move its finished builds by search
query, then hand each team a key of its new project:

```sh
bin/conveyor rpc 'Conveyor.Release.move_builds("default", "grpc", "repo:grpc", "gRPC")'
```

The target is created when missing. Every blob a moved build references is copied under
the target's prefix first (the source copies are pruned as orphans), rollups of the
affected hours and both projects' tag facets are recomputed, and the move is recorded in
the audit log. Builds still streaming are skipped.

### Raw archive

With `RAW_ARCHIVE_ENABLED=true`, every 15 minutes the `ArchiveRaw` job enqueues one job
per build that finished more than `RAW_ARCHIVE_AFTER_HOURS` ago (and whose row has not
changed for two idle windows) on the `archive` queue. Each copies the build's event
segments into one blob (a zstd-compressed `--build_event_binary_file`) and its log into
another, checks the counts against the row, and points the build at them
(`invocations.raw_status = 'archived'`, `raw_blob`, `log_blob`). From then on the Events
tab, the log viewer and the downloads read from the blob store (S3 in production): raw
data lives there after a day, PostgreSQL keeps only the build's rows. The segment rows
stay until their daily partition is dropped; the hourly partition job keeps a day that
still holds a finished build the archive has not reached, so an outage of the store
delays the drop instead of losing events.

- Storage: one object per build for events and one for the log, under the project's
  prefix, pinned; build retention makes them orphans and the nightly prune removes them.
  Requests: two PUTs per finished build (about $0.50/day of S3 PUTs at 100k builds/day)
  plus a GET per Events-tab or log view of an archived build.
- Metrics: `conveyor_raw_archived_count`, `conveyor_raw_archived_bytes`,
  `conveyor_raw_archive_failures_count{reason}` and `conveyor_raw_archive_overdue_seconds`
  (how long the oldest due build has waited past the delay). Alerts:
  `ConveyorRawArchiveBehind` (over 6 hours for 30 minutes: store credentials, bucket
  policy or a failing queue; nothing is lost, the database grows meanwhile) and
  `ConveyorRawArchiveMismatch` (a build's segments did not match its row; it is marked
  `skipped` and keeps its segments until `RETENTION_RAW_DAYS` — run
  `Conveyor.Ingest.Verify.check/2` on it).
- Rollout: enable, watch the gauge fall to zero and the failures stay at zero for a day,
  then lower `RETENTION_RAW_DAYS` (at least `RAW_ARCHIVE_AFTER_HOURS/24 + 1`, so 2 with
  the default delay). Turning it off again is safe: archived builds keep reading from the
  store, new ones stay in the segments.

### Raw log (blob mode)

With `RAW_LOG=blob` the raw bytes leave the database's commit path. A writer shard's group
commit (every `RAW_LOG_FLUSH_MS`, 1 s; sooner when `RAW_LOG_FLUSH_BYTES`, 4 MB, of batches
wait, and at once when a stream ends) first writes one object holding the group's
compressed event and log payloads to the blob store (`BLOB_STORE`: S3 or the disk
directory) under `rawlog/<node>/<shard>/<ulid>`, then commits the segment rows with a byte
range (`object_key`, `object_offset`, `object_length`) in place of the payload. The
acknowledgement follows the commit, which follows the object write, so "stored" means the
object is written and the index committed. Objects span projects, are never served by URL
and are read only by range through the server. Readers (Events tab, log viewer, downloads,
`Invocations.raw_frames/1`) resolve both forms row by row, with a build's ranges in one
object fetched as one GET, and the raw archive compacts a build's rows into its
per-project blobs as before whichever form they have, so rows written in either mode stay
readable for their whole retention.

- Sweep: every object is registered in `raw_log_objects` before it is written. Daily at
  04:30 UTC `RawLogSweep` deletes the objects registered more than `RETENTION_RAW_DAYS + 1`
  days ago (the bytes, then the row) and never one registered on or after the day of the
  oldest segment partition that still exists: a day the hourly drop has not reached, or
  that the archive's guard keeps, keeps its objects (`docs/spec/RawLog.tla`). Orphans of a
  commit that failed after its put, or of a node that died in between (the client never
  saw an ack and resends), go the same way, and so do the bytes of a batch that left its
  group after the object was written (fenced, expired or failed: the rest of the group
  commits against the same object, and those bytes stay in it with no row pointing at
  them); nothing is listed and nothing is reference-counted. `conveyor_raw_log_sweep_failed_count` counts objects it could not
  delete; they are retried the next day. The sweep runs in both modes, so objects left by
  a blob-mode period are collected after a switch back.
- Cost: the PUTs. A node issues at most `INGEST_WRITER_SHARDS × 1000 / RAW_LOG_FLUSH_MS`
  per second whatever the event rate (8 shards at 1 s: 8/s, about $3.50/day on S3), plus
  one per 4 MB received under flat-out load; an idle shard writes nothing. Reads are one
  ranged GET per object a build touches. Mid-build acks wait up to `INGEST_BATCH_FLUSH_MS`
  plus `RAW_LOG_FLUSH_MS` (measured p50 1.6 s, p99 3 s on paced builds; the end of a build
  flushes at once), see PLAN §25 "Ack latency in blob mode".
- Disk store: an object is written under a temporary name, synced, renamed into place
  and its directory synced before the batches in it are acknowledged (`RAW_LOG_FSYNC`,
  on by default; about 10 ms per object on the laptop).
- Metrics: `conveyor_raw_log_put_count` and `conveyor_raw_log_put_bytes` (objects and
  bytes written), `conveyor_raw_log_put_failed_count`, `conveyor_raw_log_sweep_failed_count`.
- When `conveyor_raw_log_put_failed_count` rises: a group's object is put once; a put
  that fails is tried again under the same key after 50, 200 and 800 ms, and if the store
  still refuses, the whole group fails (its streams end with UNAVAILABLE and Bazel
  resends). No batch tries an object of its own, so a store outage costs four puts per
  group, not one per batch. Nothing is acknowledged that is not stored, but
  `conveyor_ingest_ack_latency_us` climbs and, if every put fails, no batch commits and
  clients give up at their timeout. Check, in order: the
  store itself (raw-log calls are not counted in `conveyor_blobs_errors_count{op}`, so
  that series rising too means the whole store is down, the raw-log counter alone means
  something specific to the `rawlog/` prefix: on S3 the credentials, the bucket's region
  and the policy for `PutObject`, `GetObject` and `DeleteObject` under `rawlog/`, which
  is outside the per-project prefixes; on the disk backend free space and permissions on
  `BLOB_DIR`), the node's log (`raw log put rawlog/… failed: …` carries the store's
  reason), then that `conveyor_raw_log_put_count` resumes. Failed puts leave rows in `raw_log_objects` with
  no object behind them; the sweep removes them with the rest. The table's size is one
  row per object: `SELECT count(*), min(inserted_at) FROM raw_log_objects` (at most
  shards × 86,400 × 1000 / `RAW_LOG_FLUSH_MS` rows per node and day; `min` older than
  `RETENTION_RAW_DAYS + 2` days means the sweep is not running or is failing).
- Switching modes: `RAW_LOG` can change in either direction with a restart and nothing to
  migrate, since rows keep their form and readers resolve both (a build streaming across
  the switch has rows of both kinds). Objects written in blob mode stay, and keep being
  read, until the sweep removes them after `RETENTION_RAW_DAYS + 1` days, so keep the
  store's credentials and the `raw_log_objects` table until then. Going back to postgres
  mode puts the segment bytes back into the database's WAL and IOPS (docs/capacity.md
  "Raw log" has the difference).

### Database parameters

Two PostgreSQL settings matter for the write path and both are dynamic (no restart):
`max_wal_size` and `checkpoint_timeout`. A long build's rows are rewritten on every
batch, and every checkpoint makes the next write of each touched page copy the whole page
into the WAL and later flush it, so frequent checkpoints multiply the volume's work. The
trial runs 16 GB and 15 min (`deploy/trial/conveyor.tf`); measured at 5,000 paced streams
that cut write IOPS from 778 to 286 and bytes written from 20 to 13 MB/s at the same event
rate (PLAN §25 "Linearity run"). Keep `max_wal_size` well under the volume's free space and
raise it with the volume. The volume's own limits come first on RDS gp3 below 400 GB
(3,000 IOPS, 125 MB/s): `WriteLatency` above 10 ms with `DiskQueueDepth` in the tens means
the storage, not the instance, is the ceiling; provision throughput or move to Aurora.
`wal_compression` is on by default on RDS PostgreSQL 17 (`zstd`).

## Runbooks

Each alert in `deploy/prometheus/alerts.yml` maps to one of these.

**Ack latency high** (`ConveyorAckLatencyHigh`). Bazel waits for acks at the end of every
build, so this is what engineers feel. Check `conveyor_ingest_writer_flush_duration`
first: slow flushes mean PostgreSQL (CPU, IOPS, credits on burstable instances, dead
tuples on `invocations`); fast flushes with high ack latency mean the nodes are saturated
(`vm_total_run_queue_lengths_total`, add nodes). Never raise `POOL_SIZE` past what
`max_connections` allows for all nodes.

**Commit pressure** (no rule shipped yet; the thresholds above are the ones to start
from). Every writer shard reports what it has been handed and has not answered:
`conveyor_ingest_writer_backlog_batches`, `…_bytes` and `…_oldest_ms` (sampled every 10 s),
and each group commit records how long its oldest batch waited from the worker's submit to
its outcome (`conveyor_ingest_writer_flush_wait`). On a healthy node the wait is the hold
plus a commit: about 20 ms in postgres mode, up to `RAW_LOG_FLUSH_MS` in blob mode, and
the backlog is whatever arrived during one hold. What the numbers say when they rise:

- *Oldest age and wait climbing on every shard, flush duration high*: the database is
  slow. Same checks as "Ack latency high". Nothing is lost while the age stays under
  `INGEST_WRITER_DEADLINE_MS`; clients only see slower acknowledgements.
- *Oldest age climbing on one shard only*: that shard is inside a slow commit, usually a
  lock wait on a build another node is also writing (see "Fenced commits") or a retry
  loop; `conveyor_ingest_writer_group_failed_count` says which.
- *`conveyor_ingest_writer_expired_count` rising*: batches reached the deadline before a
  commit could start. They were never written and never acknowledged; their streams end
  with UNAVAILABLE and Bazel resends. This is the node shedding load it could not commit
  in time, and it is better than the alternative (commits landing after the client has
  resent elsewhere, which fence the new stream), but it means capacity is short: the
  database first (CPU, IOPS, burst credits), then the pool (`conveyor_repo_query_queue_time`).
  Raising the deadline does not help unless the client's ack timeout is raised too.
- *`group_failed{kind="unavailable"}`*: the database refused connections or the object
  store refused a raw-log object. The group waits 50, 200 and 800 ms
  (`writer_retry_delays`) and then fails as a whole: every stream in it gets UNAVAILABLE
  and resends. Check the pool, `max_connections`, a failover in progress, or the blob
  store (with `conveyor_raw_log_put_failed_count`).
- *`group_failed{kind="contention"}`*: deadlocks or serialization failures between two
  groups, retried the same way and then halved. A few during a rolling deploy are normal.
- *`group_failed{kind="data"}`*: the database refused a row (a value too long, a
  constraint). The group is halved until the build that carries it is alone; that build's
  stream fails and the node logs `writer shard N: 1 of M units failed: …`. It is a bug in
  the normalizer or a schema drift: the log line has the Postgres error.
- *`group_failed{kind="fenced"}`*: a group contained a stale batch and was attempted again
  without it: the count of fenced retries. It moves with `conveyor_ingest_fenced_count`.

`Conveyor.Ingest.WriterPool.pressure/0` returns the pool's total backlog and the oldest
age from the same counters (`bin/conveyor rpc 'IO.inspect(Conveyor.Ingest.WriterPool.pressure())'`).

**Fenced commits** (`ConveyorFencedCommits`). Two nodes wrote the same invocation. A
handful after a client reconnected through a balancer is normal: the resend lands on
another node, which resumes from the row, and the first node's late batch is fenced. A
steady rate without client drops means a balancer sends one build's connections to
several nodes, or lifecycle events reach a node that starts work it does not own; check
the balancer's stickiness and the version of Conveyor (lifecycle events must never start a
worker).

**Job backlog** (`ConveyorJobBacklog`). `conveyor_oban_jobs_count{state="available"}`
grows and the oldest waiting job ages: no node is fetching (all nodes down or the queue
paused), jobs with `attempt = max_attempts` left in `available` by a manual edit (rescue
with `Oban.retry_all_jobs`), or parses slower than their timeout. See "Stuck jobs" above.

**Blob store errors** (`ConveyorBlobErrors`). Reads or writes failed against disk or S3:
credentials expired, bucket policy changed, disk full. Profiles and test outputs of new
builds show as unavailable until fixed; nothing about the build itself is lost.

**Node not draining / not ready**. `/health/ready` stays 503 after a deploy: the database
is unreachable (connection string, TLS bundle, security group) or migrations failed at
boot (`docker logs` / pod logs show "Could not create schema migrations table" when the
database itself is the problem). A node that never finishes draining holds open streams
longer than `SHUTDOWN_DRAIN_SECONDS`; the balancer's deregistration delay must exceed it.

**Database full or slow**. Retention is the lever. With execution logs uploaded, spawn
rows are the bulk (`SELECT pg_total_relation_size('spawns')`): lower `RETENTION_SPAWN_DAYS`.
Otherwise enable the raw archive and lower `RETENTION_RAW_DAYS` (raw events and logs), then `RETENTION_DAYS` per project in Settings; run
`VACUUM` on `invocations` if dead tuples exceed a few percent. Growth per build is about
27 KB compressed for small builds and scales with targets, actions and log size.

## Backups

PostgreSQL is the only state that matters; blobs are derivable (Bazel can re-upload
profiles) but cheap to keep. Rehearsed on the AWS trial (2026-09-22): an RDS snapshot of
the live `db.t3.micro` took about 3 minutes, restoring it into a new instance about 9,
and `aws s3 sync` of the blob bucket (825 objects) 16 seconds; a Conveyor release pointed
at the restored instance (`bin/conveyor eval` with `Ecto.Migrator.with_repo`) reported the
same row counts (invocations, spawns, blobs, artifacts, projects, keys) and all 11
migrations applied. A fresh `deploy/trial` stack takes `-var db_snapshot_identifier=…`. Standard base backups plus WAL archiving, or the managed
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
