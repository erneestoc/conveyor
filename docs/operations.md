# Operations

## Health

- `GET /health/live`: the node is up.
- `GET /health/ready`: a balancer should send this node new connections. 200 while the
  node has reached its database, is not draining, and is not the one overloaded node of a
  cluster that has room elsewhere (see "Overload" below). It turns 503 the moment a drain
  starts. The answer is read from the node's admission state, no query per probe; the body
  names the admission state and the three checks (`database`, `draining`, `overloaded`).

## Metrics

`GET /metrics` serves Prometheus text (set `METRICS_TOKEN` for the scraper; without it only an admin session may read it). A Grafana
dashboard is in `deploy/grafana/conveyor.json`. The series that matter:

| Series | Alert when |
|---|---|
| `conveyor_ingest_ack_latency_us` (histogram, buckets to 60 s) | p99 above 250 ms for 5 minutes: Bazel's end-of-build wait grows. Acks of resent, already committed events are not in it (`conveyor_ingest_ack_resent_count`) |
| `conveyor_ingest_writer_flush_duration` (histogram, ms) | p99 above 500 ms: PostgreSQL slow or contended |
| `conveyor_repo_query_queue_time` (histogram, ms) | p99 above 50 ms: pool too small or database saturated |
| `conveyor_ingest_batch_committed_events` (counter) | rate drops to zero while streams are open |
| `conveyor_ingest_streams_count`, `conveyor_ingest_workers_count` (gauges) | near `MAX_STREAMS_PER_KEY` times keys |
| `conveyor_ingest_fenced_count` (counter) | any increase that repeats: two nodes wrote one invocation (balancer or lifecycle problem) |
| `conveyor_ingest_writer_backlog_oldest_ms{shard}` (gauge), `conveyor_ingest_writer_flush_wait` (histogram, ms) | oldest above 5,000 ms for a minute, or wait p99 above 5,000 ms: commits are not keeping up; batches expire at `INGEST_WRITER_DEADLINE_MS` (20 s). See "Commit pressure" below |
| `conveyor_ingest_writer_backlog_batches{shard}`, `conveyor_ingest_writer_backlog_bytes{shard}` (gauges) | growing over several scrapes: the same, earlier |
| `conveyor_ingest_writer_expired_count` (counter) | any increase: batches waited past their deadline and their streams failed; clients are resending |
| `conveyor_ingest_writer_group_failed_count{kind}` (counter) | `unavailable` or `data` at all; `contention` repeating; `fenced` follows `conveyor_ingest_fenced_count` |
| `conveyor_admission_state_level`, `conveyor_admission_state_pressure`, `conveyor_admission_state_ready` (gauges) | level 2 for two minutes (`ConveyorShedding`), level 3 (`ConveyorCritical`); see "Overload" below |
| `conveyor_admission_refused_count{door,reason}`, `conveyor_admission_slowed_count` (counters) | `door="event"` at all: open streams are being failed to shed load |
| `conveyor_ingest_ack_resent_count` (counter) | a rate that rivals the ack rate: clients are resending (a retry storm, or a balancer moving streams) |
| `conveyor_oban_jobs_count{queue,state}`, `conveyor_oban_oldest_available_seconds{queue}` (gauges) | oldest waiting job older than 10 minutes: the queue is not draining |
| `conveyor_blobs_errors_count{op}` (counter) | any increase: blob store credentials, bucket policy or disk |
| `conveyor_raw_log_put_failed_count`, `conveyor_raw_log_sweep_failed_count` (counters) | any increase: the blob store refuses raw-log writes or deletes (`RAW_LOG=blob`); see "Raw log (blob mode)" below |
| `conveyor_raw_log_sweep_backlog_objects`, `conveyor_raw_log_sweep_backlog_overdue_seconds` (gauges) | above 0 for more than a few hours: the raw-log sweep is not keeping up or is failing; see "Raw log (blob mode)", "When the sweep falls behind" |
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

With `RAW_ARCHIVE_ENABLED=true`, every 15 minutes the `ArchiveRaw` job compacts the builds
that finished more than `RAW_ARCHIVE_AFTER_HOURS` ago (and whose row has not changed for
two idle windows), oldest first, on the `archive` queue. It works in batches of up to
2,000 builds: the raw-log objects a batch points into are read once for all of its builds
(at most 64 MB read ahead; a batch that points at more is cut), then each build's event
segments become one blob (a zstd-compressed `--build_event_binary_file`) and its log
another, the counts are checked against the row, and the build is pointed at them
(`invocations.raw_status = 'archived'`, `raw_blob`, `log_blob`). A run lasts at most nine
minutes and continues a second later when builds remain; it stays one job, so runs never
overlap. From then on the Events tab, the log viewer and the downloads read from the blob
store (S3 in production): raw data lives there after a day, PostgreSQL keeps only the
build's rows. The segment rows stay until their daily partition is dropped; the hourly
partition job keeps a day that still holds a finished build the archive has not reached,
so an outage of the store delays the drop instead of losing events.

- Storage: one object per build for events and one for the log, under the project's
  prefix, pinned; build retention makes them orphans and the nightly prune removes them.
  Requests: two PUTs per finished build (about $0.50/day of S3 PUTs at 100k builds/day)
  plus a GET per Events-tab or log view of an archived build. In blob mode the archive
  also reads the raw log: about one ranged GET per raw-log object when the builds of a
  batch ran together (measured 1.4 per build on 1,500 paced builds; it was one per segment
  row, 15.7 per build, before batches: PLAN §26.5).
- Reading an archived build: the events blob is one compressed stream. An Events-tab page
  decompresses it from the start up to the page and stops (5 to 15 ms on a 60,000-event
  build from disk; from S3 the object is downloaded first).
- Metrics: `conveyor_raw_archived_count`, `conveyor_raw_archived_bytes`,
  `conveyor_raw_archive_failures_count{reason}` and `conveyor_raw_archive_overdue_seconds`
  (how long the oldest due build has waited past the delay). Alerts:
  `ConveyorRawArchiveBehind` (over 6 hours for 30 minutes: store credentials, bucket
  policy or a failing queue; nothing is lost, the database grows meanwhile) and
  `ConveyorRawArchiveMismatch` (a build's segments did not match its row; it is marked
  `skipped` and keeps its segments until `RETENTION_RAW_DAYS` — run
  `Conveyor.Ingest.Verify.check/2` on it).
- A build that fails to archive (a read or a put the store refused) is logged, counted
  under `reason="error"`, left as it was and tried again by the next run; the others of
  its batch are not affected. One build by hand:
  `Conveyor.RawStore.compact(id)` from a remote shell.
- Rollout: enable, watch the gauge fall to zero and the failures stay at zero for a day,
  then lower `RETENTION_RAW_DAYS` (at least `RAW_ARCHIVE_AFTER_HOURS/24 + 1`, so 2 with
  the default delay). Turning it off again is safe: archived builds keep reading from the
  store, new ones stay in the segments.
- Upgrading from 0.2.3 with the archive on: archived builds with more than about 128 KB
  of events or log could not be read back (the Events tab, the log and the downloads
  failed) until the release that carries the fix in `Conveyor.RawStore.Codec`. Their
  blobs are intact; nothing has to be re-archived.

### Raw log (blob mode)

With `RAW_LOG=blob` the raw bytes leave the database's commit path. A writer shard's group
commit (every `RAW_LOG_FLUSH_MS`, 1 s; sooner when `RAW_LOG_FLUSH_BYTES`, 4 MB, of batches
wait, and at once when a stream ends) first writes one object holding the group's
compressed event and log payloads to the blob store (`BLOB_STORE`: S3 or the disk
directory) under `rawlog/<node>/<shard>/<ulid>`, then commits the segment rows with a byte
range (`object_key`, `object_offset`, `object_length`) in place of the payload. The
acknowledgement follows the commit, which follows the object write, so "stored" means the
object is written and the index committed. Objects span projects, are never served by URL
and are read only by range through the server. Every reader goes through
`Conveyor.RawStore` (Events tab, log viewer, downloads, the oracle), which resolves both
forms row by row, and the raw archive compacts a build's rows into its per-project blobs
whichever form they have, so rows written in either mode stay readable for their whole
retention. The raw log uses the same adapter as the blobs (`Conveyor.Blobs.Adapter`), so
any backend that serves blobs serves it. `rawlog` is reserved: no project slug or blob
prefix may be `rawlog`.

- Sweep: every object is registered in `raw_log_objects` before it is written. Hourly at
  minute 30 `RawLogSweep` deletes the objects registered more than `RETENTION_RAW_DAYS + 1`
  days ago and never one registered on or after the day of the oldest segment partition
  that still exists: a day the hourly drop has not reached, or that the archive's guard
  keeps, keeps its objects (`docs/spec/RawLog.tla`; the rules are in one module,
  `Conveyor.RawStore.Expiry`). It works in pages of 1,000: the objects of a page are
  deleted in bulk (one S3 DeleteObjects request; a loop of unlinks on disk), then the
  rows of the keys the store reports deleted or already absent. A run lasts at most ten
  minutes and enqueues its continuation when objects remain. Hourly, not daily, because
  blob mode writes all day: at one object per shard per second a node registers up to
  691,000 objects a day (and flat-out load has measured 150 a second), and the previous
  daily run of at most 10,000 could never catch up. Measured: 2,500 objects in 0.17 s
  against MinIO (about 15,000 a second) and 2,500 in under a second on disk, so one
  ten-minute run covers days of one node's writes.
  Orphans of a commit that failed after its put, or of a node that died in between (the
  client never saw an ack and resends), go the same way, and so do the bytes of a batch
  that left its group after the object was written (fenced, expired or failed: the rest
  of the group commits against the same object, and those bytes stay in it with no row
  pointing at them); nothing is listed and nothing is reference-counted. The sweep runs in
  both modes, so objects left by a blob-mode period are collected after a switch back.
- When the sweep falls behind: `conveyor_raw_log_sweep_backlog_objects` is the number of
  objects past their date that are still registered (counted up to 100,000) and
  `conveyor_raw_log_sweep_backlog_overdue_seconds` how long the oldest has been past it;
  both are 0 when the sweep keeps up. Alert `ConveyorRawLogSweepBehind` fires when the
  oldest is more than a day late. Check, in order: that the job runs
  (`conveyor_oban_jobs_count{queue="maintenance"}`, the `oban_jobs` rows of
  `Conveyor.Workers.RawLogSweep`: a run ends with `deleted`, `failed`, `remaining?`);
  `conveyor_raw_log_sweep_failed_count` and `conveyor_blobs_errors_count{op="delete_objects"}`
  (the store refuses deletes: on S3 the policy needs `s3:DeleteObject` on `rawlog/*`;
  DeleteObjects is one POST on the bucket with a `Content-MD5` header, which some
  S3-compatible stores and proxies reject); and whether the backlog is real work (a
  retention just lowered, or a long partition hold by the archive's guard that ended: the
  objects of all those days become due at once and drain at thousands a second). A
  refused object keeps its row and is tried again by the next run. To run one now:
  `Oban.insert(Conveyor.Workers.RawLogSweep.new(%{}))`; to see what a shorter retention
  would delete at a given time, `Conveyor.RawStore.expiry_backlog(~U[…])`.
  **Do not** put an S3 lifecycle expiration on `rawlog/` instead: it knows an object's age
  and nothing else, and age alone deletes bytes under acknowledged rows when a partition
  is kept past its date (`RawLog_current.cfg`).
- Cost: the PUTs. A node issues at most `INGEST_WRITER_SHARDS × 1000 / RAW_LOG_FLUSH_MS`
  per second whatever the event rate (8 shards at 1 s: 8/s, about $3.50/day on S3), plus
  one per 4 MB received under flat-out load; an idle shard writes nothing. Reads are one
  ranged GET per object a build touches (an Events-tab page reads only the rows that
  cover it); the archive reads each object about once per batch (above); the sweep is one
  request per 1,000 objects. Mid-build acks wait up to `INGEST_BATCH_FLUSH_MS` plus
  `RAW_LOG_FLUSH_MS` (measured p50 1.6 s, p99 3 s on paced builds; the end of a build
  flushes at once), see PLAN §25 "Ack latency in blob mode".
- Disk store: an object is written under a temporary name, synced, renamed into place
  and its directory synced before the batches in it are acknowledged (`RAW_LOG_FSYNC`,
  on by default; about 10 ms per object on the laptop).
- Metrics: `conveyor_raw_log_put_count` and `conveyor_raw_log_put_bytes` (objects and
  bytes written), `conveyor_raw_log_put_failed_count`, `conveyor_raw_log_sweep_failed_count`,
  the two backlog gauges above, and `conveyor_blobs_errors_count{op}` with
  `op="put_object"`, `"get_range"` or `"delete_objects"` for the raw log's calls.
- When `conveyor_raw_log_put_failed_count` rises: a group's object is put once; a put
  that fails is tried again under the same key after 50, 200 and 800 ms, and if the store
  still refuses, the whole group fails (its streams end with UNAVAILABLE and Bazel
  resends). No batch tries an object of its own, so a store outage costs four puts per
  group, not one per batch. Nothing is acknowledged that is not stored, but
  `conveyor_ingest_ack_latency_us` climbs and, if every put fails, no batch commits and
  clients give up at their timeout. Check, in order: the store itself (raw-log calls are
  counted in `conveyor_blobs_errors_count{op}` like every other call to the store:
  `op="put_object"` alone rising means something specific to the `rawlog/` prefix, the
  blob operations `put`, `stream`, `delete` rising too means the whole store is down; on
  S3 the credentials, the bucket's region and the policy for `PutObject`, `GetObject`
  and `DeleteObject` under `rawlog/`, which is outside the per-project prefixes; on the
  disk backend free space and permissions on `BLOB_DIR`), the node's log
  (`raw log put rawlog/… failed: …` carries the store's reason), then that
  `conveyor_raw_log_put_count` resumes. Failed puts leave rows in `raw_log_objects` with
  no object behind them; the sweep removes them with the rest. The table's size is one
  row per object: `SELECT count(*), min(inserted_at) FROM raw_log_objects` (at most
  shards × 86,400 × 1000 / `RAW_LOG_FLUSH_MS` rows per node and day).
- A ranged read that fails (the store is down, an object is gone) is an error for the
  reader that asked: the page, the download or the archive of that build fails and says
  which object and range (`raw log rawlog/… range …`); it never returns fewer bytes.
- Switching modes: `RAW_LOG` can change in either direction with a restart and nothing to
  migrate, since rows keep their form and readers resolve both (a build streaming across
  the switch has rows of both kinds). Objects written in blob mode stay, and keep being
  read, until the sweep removes them after `RETENTION_RAW_DAYS + 1` days, so keep the
  store's credentials and the `raw_log_objects` table until then. Going back to postgres
  mode puts the segment bytes back into the database's WAL and IOPS (docs/capacity.md
  "Raw log" has the difference).

### Blob prefixes

A project's blobs live under its prefix (the slug, or the "blob prefix" in its storage
settings). A project owns its prefix: one that another project uses, or still has blobs
under, is refused, and so is `rawlog`, which is the server's. Installations from before
this check may have two projects on one prefix; deleting a blob of one then keeps the
object while the other holds a row for the same content, so nothing is lost, but give one
of them its own prefix (new blobs go there, old ones stay readable where they are). To
find such pairs:

```sql
SELECT prefix, array_agg(DISTINCT project_id) FROM blobs
WHERE prefix IS NOT NULL GROUP BY prefix HAVING count(DISTINCT project_id) > 1;
```

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

**Commit pressure** (`ConveyorCommitPressure`, `ConveyorBatchesExpired`). Every writer shard reports what it has been handed and has not answered:
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

### Overload

A node measures how far its commits are behind and refuses work it could not acknowledge
in time, new work first. The measure is **pressure**: the age of the oldest batch any
writer shard has not answered, beyond the writer's hold, as a fraction of
`INGEST_WRITER_DEADLINE_MS` (also the mean wait for a database connection against twice
the pool's queue target, and the bytes waiting for the writer against
`ADMISSION_MAX_BACKLOG_MB`; the worst of the three counts). At 1.0 batches expire. The
node samples it four times a second and is in one of four states
(`conveyor_admission_state_level`, and `admission` in the body of `/health/ready`):

| Level | Enters / leaves at (20 s deadline) | What the node does | What clients see |
|---|---|---|---|
| 0 normal | | takes everything | |
| 1 elevated | 3 s / 1 s | refuses new builds of an API key that holds more than its share of the node's streams (streams ÷ keys with streams) | that key: UNAVAILABLE on new builds, retried by Bazel |
| 2 shedding | 5 s / 2 s | refuses a share of the new builds that grows with the pressure, from none at 5 s to all at 10 s (`conveyor_admission_state_pressure` 0.25 to 0.50), at the notification that announces a build or at its first event; the same builds on every node and on every retry. The share rises with the pressure at once and falls by 2 points a second (`conveyor_admission_state_builds_refused` shows it, and `conveyor_admission_state_events_refused` the share of builds in progress; a node back at level 0 may still be taking builds back, for up to 50 s). Builds in progress continue, and a build that reconnects is taken | refused builds: UNAVAILABLE "this node is overloaded", retried by Bazel; open builds: slower acknowledgements |
| 3 critical | 15 s / 10 s | refuses every new build, and a share of the builds in progress that grows from none at 15 s to all at 20 s: their next event, and their stream when they reconnect (the same builds each time, so the others can finish) | the shed builds fail fast with UNAVAILABLE instead of waiting 30 s for an acknowledgement that would not come |

A level is left only at its lower threshold, so a node does not flap around one value. A
refusal writes nothing and acknowledges nothing: the client resends, and behind a balancer
the retry may reach a node with room. Refusals are counted
(`conveyor_admission_refused_count{door,reason}`), not logged per request; the state
changes are logged (`admission: normal -> shedding (pressure 0.3 …)`).

**Readiness under overload.** A shedding node keeps answering `/health/ready` with 200.
It leaves the balancer only when it has been shedding for 10 s **and** more than half of
the other nodes it hears from are not: then it is the outlier and the cluster has room.
When the cause is shared (the database, its volume), every node sheds and none leaves:
taking all of them out would turn a slow system into an unreachable one, and an
orchestrator that replaces unready nodes would restart healthy ones (seen on the trial
with a throttled database). For the same reason, a database that every node has lost does
not make them unready either; a node that alone cannot reach it, or has never reached it,
is not ready. A node without peers keeps the old rule for the database (not ready without
it, after three failed probes two seconds apart) and never reports unready for pressure. A node that left for pressure stays
out for at least 30 s. Keep instance replacement on the node's own health
([production](production.md)), never on readiness.

**What to do.**

- *`ConveyorShedding` on one node.* That node is the outlier: a writer shard inside a slow
  commit (lock wait on a build another node also writes: "Fenced commits"), a noisy
  neighbour, a node smaller than the others. It will leave the balancer by itself. Look at
  `conveyor_ingest_writer_backlog_oldest_ms{shard}` on it and at
  `conveyor_ingest_writer_group_failed_count`.
- *`ConveyorShedding` on every node.* The database is the bottleneck: CPU, the volume's
  IOPS or throughput cap, burst credits, the pool (`conveyor_repo_query_queue_time`). The
  nodes are protecting the builds in progress; the refused ones fail their upload after
  Bazel's retries. Add database capacity, or lower the load (`MAX_STREAMS_PER_KEY`). Adding
  nodes does not help and adds connections. Do not restart nodes: their open streams would
  resend elsewhere.
- *`ConveyorCritical`, `ConveyorEventsRefused`.* Shedding new builds was not enough: open
  streams are being failed. The same causes, further along; if only the first minutes of a
  burst look like this, the thresholds are doing their job.
- *`ConveyorBatchesExpired` without a level above 0.* Admission is off (`ADMISSION=off`)
  or the pressure rose faster than a sample (a database that stopped answering at once).
- *`ConveyorKeyAboveShare`.* One key holds more than its share while the node is under
  pressure; its new builds are refused before anybody else's. Lower its
  `max_streams` override or give it capacity.
- *Too eager, or not eager enough.* `ADMISSION_THRESHOLDS` moves the levels (fractions of
  the deadline, enter/exit per level). Later shedding trades fewer refused builds for
  longer acknowledgements of the open ones; the numbers behind the defaults are in
  `PLAN.md` §26.4.

The per-key limits are part of the same door and independent of the level: a key at
`MAX_STREAMS_PER_KEY` gets RESOURCE_EXHAUSTED (429 for the HTTP upload), a key above
`MAX_EVENTS_PER_SECOND_PER_KEY` is slowed down (`conveyor_admission_slowed_count`), never
failed. The HTTP upload answers 503 with `Retry-After` when the node sheds.

Flow control helps before any of this: a handler that stops reading (a session holding
its reply because 2,000 events are uncommitted, a key above its rate) closes the HTTP/2
window of its stream, so Bazel stops sending instead of the node buffering.

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

**Node not draining / not ready** (`ConveyorNotReadyForLong`). `/health/ready` stays 503 after a deploy: the database
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
