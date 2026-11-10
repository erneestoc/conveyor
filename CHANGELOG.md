# Changelog

## Unreleased

- **Security: an invocation id belongs to its project.** An API key of one project that
  knew a build id of another could append events to that build and mark it finished over
  gRPC. Stream and lifecycle requests for an id owned by another project now get NOT_FOUND
  and write nothing. Background jobs carry the project and load the build inside it.
- **Stream session (PLAN §26.2):** the ingest protocol is one pure module
  (`Conveyor.Ingest.Session`: inputs in, effects out) with the worker process as wiring;
  its rules are tested as tables of the TLA+ scenarios. Fixed with it: a worker no longer
  waits for ever when its writer process dies (the stream fails with UNAVAILABLE and Bazel
  resends); a failed batch ends the gRPC stream at once instead of after the client stops
  sending, and is never reported as a sequence gap; a client that resumes within
  `INGEST_LINGER_MS` of an idle disconnect keeps its worker and its build finishes as
  finished, not `disconnected`; a database error while recording the finish notification is
  UNAVAILABLE; acknowledgements echo the stream id; `PUT /api/v1/invocations/:id/bep`
  commits a file in a few batches instead of one batch hold per event.
  `Invocations.get!/1` is removed (use `get/2` with `project_ids`).

- **Commit pipeline (PLAN §26.3):** the writer is a pipeline with one promise: a submitted
  batch gets exactly one outcome (committed, fenced, expired or failed) before a deadline.
  Fixed with it: a group commit that failed no longer falls back to one transaction and
  one new raw-log object per batch (a group is planned and stored once, and what follows a
  failed attempt is a bounded policy: retry while the database or the store is unavailable
  and then fail the group, halve the group to find a row the database refuses); a batch
  that has waited `INGEST_WRITER_DEADLINE_MS` (new, 20 s) fails as expired instead of
  committing after Bazel's 30 s ack timeout and fencing the stream that took over; the
  fenced update runs first in the transaction, so a stale group aborts before it writes
  child rows; raw-log objects on the disk store are written atomically and synced before
  the ack (`RAW_LOG_FSYNC`, new, default on). New on `/metrics`: writer backlog per shard
  (`conveyor_ingest_writer_backlog_batches`, `_bytes`, `_oldest_ms`), the wait of the
  oldest batch per group commit (`conveyor_ingest_writer_flush_wait`),
  `conveyor_ingest_writer_group_failed_count{kind}` and
  `conveyor_ingest_writer_expired_count`; docs/operations.md "Commit pressure" says what to
  do when they rise. Finished workers are hibernated by the commit that leaves them idle
  (flat-out bench: worker memory at the peak 293–407 MB → 65–95 MB for 10,000 lingering
  workers). Writer settings are read once when the node starts.
- **Derived rows nothing read are no longer stored (PLAN §26.1):** `named_sets` rows and
  `targets.output_groups` were written for every build and read by nothing (the raw BEP
  stream keeps the same data). Flat-out bench: WAL 721 → 662 bytes/event, storage
  30.2 → 28.4 KB/build on the small fixtures; on real builds `named_sets` was about a third
  of the database. `Invocations.named_sets/1` and the `NamedSet` schema are removed.
  **Follow-up owed in the next release:** a migration dropping table `named_sets` and column
  `targets.output_groups` (not in this one: old nodes still write both during a rolling
  deploy). Existing rows stay until then; `TRUNCATE named_sets` is safe once all nodes run
  this release.
- **Linearity run (PLAN §25):** six nodes and an 8-vCPU database in blob mode, flat out
  to 66k events/s and paced at 5,000 streams: the database's CPU is linear at ≈ 0.6 % per
  1,000 events/s on 8 vCPUs, the gp3 volume is the first ceiling, and `max_wal_size` 16 GB
  with `checkpoint_timeout` 15 min cuts the paced load's write IOPS by 63 % (now the trial's
  parameter-group defaults). Fixed on the way: the fleet generator died after two minutes
  flat out (`cacerts` copied into the literal area per connection; it passes `cacertfile`
  now), `FetchProfile` jobs were inserted and cancelled for every build of a project without
  a cache endpoint (the endpoint is checked at finalize time), the writer's grouped upserts
  insert rows in conflict-key order so two nodes writing one build cannot deadlock on them,
  and `bench/fleet.sh` waits for a task's lagging log lines before reading its summary.
- **The raw log (`RAW_LOG=blob`, off by default): raw bytes leave the database's commit
  path.** In blob mode a writer shard puts each group commit's compressed event and log
  bytes into one object in the blob store (S3 or disk) and the segment rows keep a byte
  range; acknowledgements follow the object write and the commit, readers fetch by range,
  the archive compacts as before, and a daily sweep deletes objects older than the raw
  retention plus a day (objects are registered before they are written, so no listing and
  no orphans). Mid-build acks wait up to `RAW_LOG_FLUSH_MS` (1 s) more. PLAN §25 step 2.
- **Raw log: coalesced reads, a size-triggered flush, the S3 contract test.** Readers fetch
  a build's byte ranges through `RawLog.fetch_rows!/2`, one ranged GET per object instead
  of one per row (`[:conveyor, :raw_log, :get_range]` counts them); a writer shard in blob
  mode writes its object as soon as `RAW_LOG_FLUSH_BYTES` (4 MB) of batches wait, so a
  chatty build never fills a shard's memory for the whole hold; `mix test --only s3`
  covers `put_object`, `get_range` and `delete` for raw-log keys. Measured ack latency
  per hold is in PLAN §25 "Ack latency in blob mode": the defaults stay (writer hold 1 s,
  batch hold 2 s; sub-second mid-build acks are `INGEST_BATCH_FLUSH_MS=1000
  RAW_LOG_FLUSH_MS=250` at a third more WAL per event and four times the PUTs).
- **Raw log: the sweep stops at the oldest segment partition.** `RawLogSweep` deleted
  objects by age alone (`RETENTION_RAW_DAYS + 1` days), due on the same day as the
  partition drop; a drop that ran late (a stalled maintenance queue, or the archive's
  guard keeping a day) would have left acknowledged rows pointing at deleted bytes. The
  cutoff now never passes the day of the oldest segment partition that exists. Found by
  `docs/spec/RawLog.tla` (an acknowledged batch's bytes stay readable until its partition
  is dropped, every object is registered; four configurations in `check.sh`); the
  operations guide gained "Raw log (blob mode)".
- **Batches wait two seconds for more events (`INGEST_BATCH_FLUSH_MS` 50 → 2000).** A real
  build sends an event every few hundred milliseconds, so a 50 ms hold committed one
  segment row and one fenced invocation update per event: at 5,000 concurrent builds that
  was 1,000 write IOPS and 10 GB of segments a day on the trial. Full batches and the end
  of a stream still commit immediately; only mid-build acknowledgement latency is bounded
  by the hold, which Bazel never waits on. Laptop, 1,000 paced streams: transactions/s 302 → 171, round trips −48 %, WAL per event −39 %; 5000 roughly halves that again (PLAN §25).
- **Seeding is as fast as ingest.** `Conveyor.Seed` pushed every event and waited for its
  commit, which took minutes per real build against a networked database and tripped a
  two-minute limit per build; it now streams a build's events the way the gRPC handler
  does and waits for the last acknowledgement, with no per-build limit.
- **A watched builds list no longer floods its viewer's node.** With live updates gated on
  viewers, opening a project's builds list during the fleet test made every one of its
  5,000 workers send the full build summary (tens of KB of options and workspace status)
  four times a second to the node serving that page, which was killed out of memory within
  a minute. List-level messages now carry only the row's columns, the list applies a burst
  of updates in one pass (last message per build wins), and it keeps at most 500 rows in
  the page.
- **A fenced batch no longer makes the writer commit its whole group one batch at a
  time.** Fencing (a stale worker after another node took the build over) is routine while
  a balancer moves thousands of streams during a deploy; redoing a group of 256 batches in
  256 transactions each time left the writer hundreds of thousands of batches behind in the
  fleet test's rolling deploy. The fenced invocation's batches now fail on their own and
  the rest of the group is committed again in one transaction. The trial's nodes also run
  eight writer shards (`INGEST_WRITER_SHARDS`): writers mostly wait on a networked
  database, so more shards than vCPUs keep more transactions in flight.
- **Live updates are published only for builds somebody is watching.** Every ingest worker
  broadcast its build's summary, detail and log chunks four times a second, and across a
  cluster `Phoenix.PubSub` forwards each message to one process per other node: at about
  3,000 streams per node (the fleet test's rolling deploy under 5,000 builds) that process
  fell behind, its queue reached 6 GB and every node was killed out of memory. Pages now
  subscribe through `Conveyor.Watch`, which records the subscription in a cluster-wide
  `:pg` group, and workers broadcast a topic only while it has a subscriber anywhere.
- **The load generator survives a lost connection the way Bazel does.** Its BES client
  (`Conveyor.Bep.Replay`, behind `mix conveyor.loadgen` and the fleet tasks) gives a stream
  up when no acknowledgement arrives for `--ack-timeout-ms` (30 s) while events are
  outstanding, then resumes the same invocation from the last acknowledged event on a fresh
  connection to the next host, up to `--retries` times. Before, a connection that died
  silently behind a balancer hung the build forever, and a retry resent it from the first
  event. Found by the fleet test's rolling-deploy level.
- **Execution-log storage: input lists deduplicated, spawns on their own retention.** A
  spawn's input list (every path and digest an action read) was copied into each spawn
  row: on the AWS trial 79 % of 48,030 lists were exact duplicates holding 96 % of the
  table. Lists now live once per project and digest in `spawn_inputs`, referenced by the
  spawns; the migration moves existing lists over. Spawns are deleted after
  `RETENTION_SPAWN_DAYS` (30; per project in Settings → Storage), the build's Actions tab
  then reads "expired", and dashboards keep their execution-log sums. The store/prune race
  is modelled in `docs/spec/SpawnInputs.tla`: the list upsert takes the row lock and
  pruning re-checks references under it. Measured on three real logs: 117 MB → 4.1 MB per
  build, stores seven times faster. After upgrading, run `VACUUM FULL spawns` once to
  reclaim the dropped column's space (docs/operations.md).
- **The raw archive enqueues every due build each run.** A run took one page of 1,000,
  capping the archive at 96k builds a day although one node drains 20–30k an hour
  (measured on the trial); it now walks all due builds with a keyset cursor.
- **Builds orphaned by a dead node no longer stay "in progress" forever.** A job marks
  builds `disconnected` when their row has not changed for two idle windows (no node
  serves them; a live worker would have marked its own build disconnected after one), as
  the worker's idle timeout would have done. The trial had 28 such builds from node
  replacements and kill tests.
- **Move builds between projects.** `Conveyor.Release.move_builds(from, to, query)` (on a
  node: `bin/conveyor rpc`) moves a project's finished builds matching a search query to
  another project, creating it if needed: their blobs (profiles, artifacts, archived raw
  data) are copied under the target's prefix, both projects' rollups and facets are
  recomputed, and the move is audited. An invalid query is refused rather than read as
  "everything". For splitting a `default` project that collected every team's builds.
- **Deploys on the single-node Caddy shape without failed builds.** The trial's nodes
  restore Caddy's certificate store from SSM before Caddy starts and save it when it
  changes, so a replacement node serves TLS as soon as the Elastic IP moves: a 10-minute
  paced run through an instance refresh completed 396 of 396 builds (109 of 477 failed
  before, during ≈ 50 s of certificate issuance). `docs/production.md` recommends the same
  for any single-node Caddy setup.

## 0.2.3 (2026-09-26)

- **Raw write-behind to the blob store (off by default: `RAW_ARCHIVE_ENABLED`).** A day
  after a build finishes (`RAW_ARCHIVE_AFTER_HOURS`, 24), its raw BEP events and log move
  from the PostgreSQL segment partitions into the blob store as one object each: the
  events object is a zstd-compressed `--build_event_binary_file`. Every acknowledgement
  is still a PostgreSQL commit; the Events tab, the log viewer, the downloads and the
  oracle read the blobs once a build is archived, byte for byte the same. Raw history
  stops growing the database and can be kept as long as the bucket allows. The partition
  drop keeps any day the archive has not finished with (a store outage delays the drop
  instead of losing events); `conveyor_raw_archive_overdue_seconds` and two alert rules
  watch it. Modelled first in `docs/spec/Archive.tla`.
- **Blob deletion no longer races a re-upload (found by model checking).** A blob deleted
  while the same content was being uploaded again could lose the new upload's bytes
  under a fresh reference: the object was deleted after the row's transaction. The object
  now goes while the row lock is held, and pinning a blob checks that its bytes exist.
  `docs/spec/Blobs.tla` gained concurrent re-uploads.
- **Retention leaves live builds alone (found by model checking).** A build still
  streaming past its retention cutoff was deleted under its worker, which fenced the
  commit and left an empty row when the client retried; retention now skips in-progress
  and disconnected builds that changed recently (`docs/spec/Retention.tla`).
- **Deploys without downtime on the EC2 shape.** The trial's boot script claims the
  Elastic IP only after the node answers `/health/ready`, and instance refreshes launch the
  new node before terminating the old one.

## 0.2.2 (2026-09-23)

- **Rollup staleness (found by model checking).** A build that changed while its hour was
  being rolled up could stay hidden until the next change; rows are now stamped from
  before their builds are read. The writer's group commit and Oban's rescue window were
  modelled too: the writer holds every property (tag counts are undercounted only when a
  committed group's acknowledgement is lost, an accepted inexactness), and the parse
  timeout is now pinned below the rescue window by a test. `docs/spec/`.

- **Blob references can no longer point at deleted bytes (found by model checking).** An
  attach pinned the blob and inserted the reference in two statements while orphan
  pruning or TTL expiry could delete the blob in between (and deleted the object before
  the row). Pin and reference are one transaction that fails when the blob is gone;
  deletions re-check under the row lock and drop the row before the object. A vanished
  profile blob makes the fetch job retry; an upload racing a deletion answers 503.
  `docs/spec/Blobs.tla`, `docs/spec/check.sh`.

## 0.2.1 (2026-09-23)

- **Ingest correctness (found by model checking).** A client that reconnected to the same
  node and resent an event the worker had absorbed but not yet committed was acknowledged
  at once; a failed commit could then lose that event for good, since Bazel never resends
  what it believes stored. A resend is now acknowledged immediately only when it is
  committed; otherwise the new connection waits for the commit. The protocol is specified
  in TLA+ (`docs/spec/`) and checked with TLC: acknowledged events are durable and every
  run completes under bounded drops and a failed commit; the configuration with the old
  rule fails in seven steps, and the pre-M10 lifecycle behaviour reproduces the trial's
  stuck builds.
- **Dashboard** loads its panels once per view (the first response paints the shell), the
  window's rollup rows are computed once per page, and the execution-log reports (cache by
  mnemonic, cache-missing targets, remote bytes) read the hourly rollups. On the trial a
  dashboard view went from 3.3–4.3 s to 0.4 s to first byte plus about 1.5 s of panels.

## 0.2.0 (2026-09-22)

Speed and capacity (PLAN §24), then project boundary, hardening and product separation
(M10). Every speed change was measured with the new benchmark harness; numbers are in
docs/capacity.md.

- **Benchmark harness.** `bench/run.sh` hosts a production build of the server, drives
  the load generator as a child process and records events per second per app vCPU and
  per PostgreSQL vCPU, WAL bytes per event, RSS per stream, storage per build, round
  trips per flush and the persistence oracle for every run.
- **Fewer statements per flush and per build.** Batches of one invocation are merged per
  flush and the fenced invocation updates of a flush go out as one statement per set of
  columns; the worker creates or loads its row in one round trip; a profile Bazel wrote
  to a local file is settled in the final batch. Round trips −24 % (−32 % for paced
  builds), transactions −42 %, WAL −3.5 %.
- **Ingest CPU.** The credential scrubber runs its regexes only on strings that can
  match: node CPU 5.5 → 3.4 vCPU at 20k events/s, ack p99 425 → 217 ms.
- **Memory per stream.** Quiet workers hibernate and finished ones drop their wide
  columns: 610 → 443 KB per open stream; a node with 10,000 finished builds lingering
  went from 3.2 GB to 1.85 GB.
- **Raw storage.** Event segments are compressed with a zstd dictionary trained on BEP
  (`priv/zstd/bep-1.dict`, retrain with `bench/train_dict.sh`); rows written before it
  still decode. Storage per build −10 %, event segments −38 %, WAL −10 %.
- **Dashboards from hourly rollups.** Summary tiles, the series, phases over time, queue
  time and actions by mnemonic read `invocation_rollups` (kept by a job every five
  minutes; reads repair missing hours themselves; segments and free-form queries stay
  exact): a dashboard load with 100k builds in range went from 2.2 s to 0.5 s.
- `INGEST_WRITER_MAX_PENDING` (default 256) bounds the batches a writer shard commits early.

- **The project is the hard boundary.** Every read is restricted in SQL to the projects
  the viewer may see: builds list and facets, invocation pages, downloads and artifacts,
  dashboards and test health, execution-log comparisons, API uploads (another project's
  id is 404 with your key), and `/metrics` without a token needs an admin session. A
  router-walking test proves it for every route.
- **Blobs per project.** Profiles, test outputs and cache uploads are keyed by project and
  stored under a per-project key prefix (the slug unless changed); projects never share
  blobs. Existing blobs are migrated to the projects that reference them.
- **Per-project retention and admins.** Retention days and blob prefix per project in
  Settings ("Storage"); admin groups let identity-provider groups administer a project at
  `/p/<slug>/settings` (keys, storage, cache endpoints, segments, audit) without global
  admin. Blobs no build references any more are pruned nightly (a storage leak before).
- **Root page lists projects** with their last seven days; the cross-project builds list
  moved to `/builds`.
- **Execution-log parser**: input sets expand as map unions (a 429-spawn log went from
  minutes to 51 ms), parses run on their own Oban queue with a 10-minute timeout, spawns
  are stored in small chunks with long statement timeouts and transient retry.
- **Lifecycle events never start a worker** on a node that does not own the stream (behind
  a balancer this fenced the real one).
- **Metrics and alerts**: `conveyor_oban_jobs_count`, `conveyor_oban_oldest_available_seconds`,
  `conveyor_ingest_fenced_count`, `conveyor_blobs_errors_count`; rules in
  `deploy/prometheus/alerts.yml` and an optional Helm `PrometheusRule`.
- **Database TLS**: `DATABASE_SSL=true` with `DATABASE_SSL_CA` (RDS global bundle).
- **Deploy**: `deploy/trial` gains a single-node Caddy edge (Let's Encrypt, gRPC on 1985),
  restore-from-snapshot, NLB cross-zone balancing, EC2-based instance health; a rehearsed
  backup and restore is documented.
- **Load generator**: `--tls` for balancers and Caddy; survives a killed server mid-stream.
- Docs: install paths per platform, capacity, roles and boundary, runbooks.

## 0.1.0 — 2026-09-19

First release.

- Build Event Service server (gRPC) with committed-before-ack durability, per-invocation
  fencing, deduplication and resume across nodes; API keys per project with per-key limits.
- Web UI: live builds list with a query language and facets, build pages (overview, log,
  timeline, targets, tests, actions, metrics, details, events), dashboard and tests pages.
- Artifacts: profile timeline and test outputs fetched from a remote cache or the built-in
  CAS sink; disk and S3 blob stores.
- Sign-in: open mode with an admin token, or OpenID Connect with group-based admin access;
  audit log; secret scrubbing of command lines and logs.
- Operations: Prometheus metrics, health endpoints, SIGTERM drain, cluster formation
  (Kubernetes, DNS, EC2 tags, static), retention for builds and raw segments, release
  image, Kubernetes manifests, EC2 auto-scaling Terraform, Grafana dashboard.
- Load generator with chaos options and a persistence oracle; measured 1,000 concurrent
  streams at p99 ack 146 ms and zero loss through a killed node (see PLAN.md §21).
- Verified end to end with Bazel 7.6, 8.3 and 9.2.
