# Changelog

## Unreleased

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
