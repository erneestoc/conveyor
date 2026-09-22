# Running Conveyor in production

What the M7 scale campaign measured and what to set. Numbers come from a laptop with
Postgres in a 2-vCPU Docker VM, so treat them as conservative; rerun the load generator
on your own hardware before committing to a size (`mix conveyor.loadgen --help`).

## Topology

- **App nodes** are stateless apart from builds in flight. A build's stream must reach the
  node that owns its worker; when a node dies, Bazel retries and the build resumes on any
  other node from the last committed event (fenced by `last_event_seq`, no cluster locks).
  Measured: one of three nodes killed with SIGKILL under load → 6000/6000 builds complete,
  340 retried elsewhere, zero events lost.
- **Postgres** is the durability boundary: an event is acknowledged only after its batch
  commits. Never run with `synchronous_commit = off` (measured to change nothing anyway).
- **Blob store** must be S3 (or compatible) with more than one node (`BLOB_STORE=s3`).
- **Single node without a balancer**: put Caddy in front (`reverse_proxy 127.0.0.1:4000`
  for the UI and `reverse_proxy h2c://127.0.0.1:1986` on `:1985` for gRPC, with Conveyor
  on `GRPC_PORT=1986`); Caddy obtains the certificate from Let's Encrypt and serves h2 to
  Bazel. `deploy/trial` does exactly this in its staging shape (`edge = "caddy"`).
- **Auto Scaling / orchestrators**: base instance replacement on the node itself
  (EC2 status, liveness), not on `/health/ready`: readiness depends on the database, and a
  slow database would otherwise replace healthy nodes and make things worse (seen on the
  trial when a burstable RDS ran out of CPU credits).
- **Network Load Balancer**: turn cross-zone load balancing on (it is off by default) or
  keep a node in every zone the balancer has an address in; otherwise connections that
  land in an empty zone are accepted and hang until Bazel's deadline (found on the trial).
- **Load balancer**: gRPC (HTTP/2) on `GRPC_PORT` (1985) and HTTP on `PORT`. Bazel opens
  one HTTP/2 connection per build. Deregistration delay must exceed
  `SHUTDOWN_DRAIN_SECONDS` so a draining node receives no new streams.

## Sizing

| Measured | Value |
|---|---|
| Ack latency, 1,000 concurrent streams paced like real builds (1 event / 500 ms), one node | p50 75 ms, p99 146 ms, max 264 ms |
| Ack latency, 200 streams replaying builds flat out, one node | p50 ≈ 0.3 s, p99 0.6–0.9 s at 13–15k events/s |
| Memory per concurrent stream | ≈ 0.9 MB (worker + HTTP/2 connection), plus ≈ 150 MB base |
| Postgres CPU | ≈ 1 vCPU per 10k events/s of fixture replay |
| Storage per build (fixture builds, compressed) | ≈ 27 KB: invocation row 9 KB, raw events 16 KB, log 1 KB; real builds scale with targets, actions and log size |

Starting points:

- **Up to 500 concurrent builds**: two app nodes with 2 vCPU / 2 GB each, Postgres with
  2 vCPU (RDS `db.m6g.large` or `db.t4g.large`), 100 GB gp3.
- **Up to 2,000 concurrent builds or sustained 20k events/s**: three app nodes with
  4 vCPU / 4 GB, Postgres with 4 vCPU (`db.m6g.xlarge`) and headroom on IOPS; the
  per-batch invocation update is the dominant Postgres cost.
- The Kubernetes manifests request 1 vCPU / 1 GiB and limit 4 vCPU / 4 GiB per pod, with
  a CPU-based HPA. The release sets `+sbwt none` so the BEAM does not busy-wait; without
  it, idle-ish nodes show over 100 % CPU and the HPA scales on nothing.

## Postgres

Applied by migrations (nothing to do): `invocations` at `fillfactor 70` with autovacuum at
2 %, LZ4 compression on the large jsonb columns, zstd segment payloads stored EXTERNAL,
and no index on columns the per-batch update touches (an index on `last_event_at` made
every update non-HOT and cost 3× in Postgres CPU).

Settings on the server:

- `max_connections` ≥ nodes × `POOL_SIZE` (default 40) + 20 for maintenance. Three nodes
  at 40 need 140. Lower `POOL_SIZE` before raising `max_connections` past ~300.
- **Connection poolers**: Conveyor uses named prepared statements, so transaction-mode
  PgBouncer is not supported. RDS Proxy works only with session pinning, which removes
  its benefit; connect directly.
- `shared_buffers` 25 % of RAM, `effective_io_concurrency` 200 on SSD, `wal_compression = lz4`.
- Storage growth is bounded by retention: `RETENTION_DAYS` (default 90, per project in
  Settings) deletes builds in batches nightly; `RETENTION_RAW_DAYS` (default 14) drops raw event and log segments by
  daily partition, so the log and events tabs of older builds are gone while their summary,
  targets, tests and metrics remain until `RETENTION_DAYS`.

## Bazel clients

```
build --bes_backend=grpcs://conveyor.example.com:1985
build --bes_results_url=https://conveyor.example.com/invocation/
build --build_event_upload_max_retries=10
build --bes_timeout=60s
build --build_metadata=CI=true --build_metadata=TEAM=infra
```

`--build_event_upload_max_retries=10` matters: Bazel's default retry budget is a few
seconds, shorter than a rolling restart.

## Limits

Per API key, enforced per node: `MAX_STREAMS_PER_KEY` (200), `MAX_EVENTS_PER_SECOND_PER_KEY`
(5,000, senders above it are slowed, never failed), `MAX_LOG_MB` (256, the rest of a log
is dropped with a marker). With N nodes a key can use up to N× these.

## Rollouts

SIGTERM starts a drain: the node stops accepting streams, reports `not ready` on
`/health/ready`, waits up to `SHUTDOWN_DRAIN_SECONDS` for open streams, then exits. Builds
still streaming when the node exits are retried by Bazel onto other nodes. Migrations run
on boot (`Conveyor.Release.migrate`); they are additive and safe to run while old nodes
serve traffic.

## Observability

`/metrics` (Prometheus) — alert on:

- `conveyor_ingest_ack_latency_us` p99 above 250 ms for 5 minutes.
- `conveyor_ingest_writer_flush_duration` p99 above 500 ms (Postgres slow or contended).
- `conveyor_repo_query_queue_time` p99 above 50 ms (pool too small or Postgres saturated).
- `conveyor_ingest_streams_count` near `MAX_STREAMS_PER_KEY` × keys.
- Postgres CPU above 70 %, dead tuples on `invocations`, TOAST growth.

`/health/live` and `/health/ready` for the balancer and orchestrator. Structured logs
carry the invocation id on every ingest error.

## Checklist before go-live

- [ ] `BLOB_STORE=s3`, bucket lifecycle rule matching `RETENTION_DAYS`.
- [ ] `SECRET_KEY_BASE`, `ADMIN_TOKEN` or OIDC configured; `BES_INGEST_AUTH=api_key`.
- [ ] TLS at the balancer for both ports; Bazel uses `grpcs://`.
- [ ] `DATABASE_SSL=true` with `DATABASE_SSL_CA` pointing at the provider's bundle (RDS: keep `rds.force_ssl=1`).
- [ ] `max_connections` sized to nodes × `POOL_SIZE`.
- [ ] Balancer deregistration delay > `SHUTDOWN_DRAIN_SECONDS`.
- [ ] Dashboards on the metrics above; a synthetic build every few minutes.
- [ ] Load generator run against the real stack: `bes_loadgen --hosts ... --api-key ... --streams 200 --retries 5`, then `mix conveyor.loadgen ... --verify` from a node with database access.
