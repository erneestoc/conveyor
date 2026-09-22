# Changelog

## Unreleased

Project boundary, hardening and product separation (M10).

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
