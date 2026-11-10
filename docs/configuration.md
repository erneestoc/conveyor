# Configuration reference

Every setting is an environment variable read when the release boots
(`config/runtime.exs`). Required variables are marked; everything else has the default
shown.

## Core

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | required | `ecto://user:pass@host/db` |
| `DATABASE_SSL` | `false` | `true` connects with TLS and verifies the server certificate (name = the host in `DATABASE_URL`) |
| `DATABASE_SSL_CA` | unset | PEM bundle to verify against; unset = the OS trust store. For AWS RDS download the [global bundle](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem) into the image or a mounted volume and keep `rds.force_ssl` on |
| `SECRET_KEY_BASE` | required | 64+ random bytes (`mix phx.gen.secret`); signs cookies and sessions |
| `PHX_HOST` | `example.com` | public hostname of the UI, used in links Bazel prints |
| `PORT` | `4000` | HTTP listener |
| `GRPC_PORT` | `1985` | Build Event Service listener |
| `FORCE_SSL` | `false` | redirect HTTP to HTTPS and send HSTS; only behind a layer-7 terminator that sets `x-forwarded-proto` (an ingress or ALB). Leave off behind a layer-4 balancer such as an NLB, which terminates TLS without adding the header. Health paths are never redirected. |
| `POOL_SIZE` | `40` | PostgreSQL connections per node |
| `ECTO_IPV6` | `false` | connect to PostgreSQL over IPv6 |
| `SHUTDOWN_DRAIN_SECONDS` | `30` | how long SIGTERM waits for open streams |
| `METRICS_TOKEN` | unset | when set, `/metrics` requires `Authorization: Bearer <token>`; when unset, an admin session (open mode without `ADMIN_TOKEN`: everyone) |

## Ingest

| Variable | Default | Meaning |
|---|---|---|
| `BES_INGEST_AUTH` | `api_key` | `none` maps every stream to the `default` project (trusted networks only) |
| `MAX_STREAMS_PER_KEY` | `200` | concurrent streams per API key per node; beyond it `RESOURCE_EXHAUSTED` |
| `MAX_EVENTS_PER_SECOND_PER_KEY` | `5000` | senders above it are slowed, never failed |
| `MAX_LOG_MB` | `256` | log bytes kept per build; the rest is dropped with a marker |
| `INGEST_BATCH_MAX_EVENTS` | `500` | events per commit batch |
| `RAW_LOG` | `postgres` | `blob`: the writer puts each group commit's raw event and log bytes into one object in the blob store (`BLOB_STORE`) and the segment rows keep only a byte range, so the database carries metadata and small index rows; acks follow the object write and the commit (PLAN §25 step 2; how it behaves, the sweep and what to check when a put fails: docs/operations.md "Raw log (blob mode)") |
| `RAW_LOG_FLUSH_MS` | `1000` | in blob mode, how long a writer shard collects batches before writing one object: at most `INGEST_WRITER_SHARDS` objects per second per node whatever the event rate (8 shards: 8 PUTs/s, about $3.50/day on S3); mid-build acks wait up to `INGEST_BATCH_FLUSH_MS` plus this (measured p50 1.6 s, p99 3 s on paced builds; shortening this alone does not help while the batch hold is 2 s, see PLAN §25 "Ack latency in blob mode") |
| `RAW_LOG_FLUSH_BYTES` | `4194304` | in blob mode, a writer shard writes its object as soon as this many bytes of batches wait (event and log bytes as received, before zstd, so the object is a few times smaller), so flat-out load never waits out the hold and objects stay bounded in size; PUTs per second then scale with throughput (one per 4 MB received) instead of with the hold |
| `RAW_LOG_FSYNC` | `true` | in blob mode on the disk store, an object is written under a temporary name, synced, renamed into place and its directory synced before the batches in it are acknowledged, so an acknowledged event survives a crash of the machine. `false` skips the two syncs (the rename stays): only for stores where losing the last seconds of acknowledged events on a power loss is acceptable. Measured on the laptop (APFS, `F_FULLFSYNC`): about 5 ms per sync, so 10 ms per object, one object per shard per hold. No effect on S3 |
| `INGEST_BATCH_FLUSH_MS` | `2000` | how long a batch waits for more events before it is committed; full batches and the end of a stream commit at once, so this bounds mid-build acknowledgement latency, not build completion. Was 50 (one row and one update per event on paced builds); 5000 halves the database's work again on large fleets of paced builds (PLAN §25) |
| `INGEST_WRITER_SHARDS` | schedulers | parallel group-commit writers; on a networked database (RDS over TLS) writers mostly wait on round trips, so set 3–4 per vCPU (the trial runs 8 on 2 vCPUs) |
| `INGEST_WRITER_FLUSH_MS` | `20` | group commit interval |
| `INGEST_WRITER_MAX_PENDING` | `256` | batches a writer shard commits early instead of waiting for the interval |
| `INGEST_WRITER_DEADLINE_MS` | `20000` | how long after a worker submits a batch its commit may still start. Later than that the batch fails as expired without touching the database, and a commit that has started runs with the rest of the budget as its timeout. Bazel waits 30 s for an acknowledgement and then resends on a new stream, so an outcome after that would only fence the stream that took over; keep this under the client's ack timeout minus `INGEST_BATCH_FLUSH_MS` |
| `INGEST_TAG_FLUSH_MS` | `1000` | tag facet count write interval |
| `INGEST_MAX_UNACKED_EVENTS` | see config | backpressure threshold per stream |
| `INGEST_IDLE_TIMEOUT_MS` | `600000` | a silent stream is marked disconnected after this |
| `INGEST_LINGER_MS` | `30000` | how long a finished build's worker waits for late lifecycle events |

## Retention

| Variable | Default | Meaning |
|---|---|---|
| `RETENTION_DAYS` | `90` | builds older than this are deleted nightly, with their targets, tests, actions and metrics; a project can set its own days in Settings |
| `RETENTION_RAW_DAYS` | `14` | raw event and log segments are dropped by daily partition after this |
| `RETENTION_SPAWN_DAYS` | `30` | execution-log spawns (the per-action rows behind "why did it run?" and the cache reports) are deleted after this and the build's log shows as expired; dashboards keep their sums. Per project in Settings → Storage; never longer than the build retention |
| `RAW_ARCHIVE_ENABLED` | `false` | move a finished build's raw events and log from PostgreSQL to the blob store (one object each) after `RAW_ARCHIVE_AFTER_HOURS`; see operations "Raw archive" |
| `RAW_ARCHIVE_AFTER_HOURS` | `24` | how long after a build finishes its raw data moves; `RETENTION_RAW_DAYS` must cover it plus a day (the server refuses to start otherwise) |
| `CAS_TTL_DAYS` | `14` | uploads through the CAS sink that no build references are pruned after this |
| `ARTIFACT_MAX_MB` | `512` | largest artifact fetched or accepted |

## Artifacts and blob store

| Variable | Default | Meaning |
|---|---|---|
| `BLOB_STORE` | `disk` | `disk` or `s3`; S3 is required with more than one node |
| `BLOB_DIR` | `/var/lib/conveyor/blobs` | disk store path |
| `S3_BUCKET` | required for s3 | |
| `S3_REGION` | `AWS_REGION` or `us-east-1` | |
| `S3_ENDPOINT`, `S3_PATH_STYLE` | unset, `false` | S3-compatible stores (MinIO, R2, Ceph) |
| `S3_PREFIX` | `blobs` | key prefix; every project stores under `<S3_PREFIX>/<project prefix>/` (the slug unless changed in Settings) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | unset | static credentials; otherwise the instance role or IRSA (IMDSv2) |
| `CAS_SINK_ENABLED` | `false` | serve a minimal ByteStream/CAS endpoint on the gRPC port so Bazel can upload profiles and test logs directly |

Cache endpoints for fetching from your own remote cache (endpoint override, custom CA,
mTLS, bearer token) are configured per project in Settings; see
[Cache endpoints](cache-endpoints.md).

## Sign-in

| Variable | Default | Meaning |
|---|---|---|
| `AUTH_MODE` | `open` | `open` or `oidc` |
| `ADMIN_TOKEN` | unset | gates Settings in open mode |
| `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | required for oidc | |
| `OIDC_SCOPES` | `openid email profile` | |
| `OIDC_GROUPS_CLAIM` | `groups` | |
| `OIDC_ADMIN_GROUPS`, `ADMIN_EMAILS` | unset | who gets Settings |
| `ALLOWED_EMAIL_DOMAINS` | unset (any) | comma-separated |

## Clustering

| Variable | Default | Meaning |
|---|---|---|
| `CLUSTER_STRATEGY` | `none` | `k8s`, `dns`, `ec2` or `epmd` |
| `CLUSTER_K8S_SERVICE` | unset | headless service name for `k8s` |
| `CLUSTER_DNS_QUERY` | unset | A record to poll for `dns` |
| `CLUSTER_EC2_TAG`, `CLUSTER_EC2_TAG_VALUE` | `conveyor-cluster`, unset | instance tag for `ec2` (instance role, IMDSv2) |
| `CLUSTER_HOSTS` | unset | `name@ip,...` for `epmd` |
| `CLUSTER_NODE_BASENAME` | `conveyor` | node name prefix |
| `CLUSTER_POLL_MS` | `5000` | discovery interval |
| `RELEASE_COOKIE` | required when clustered | Erlang distribution cookie |
| `DIST_PORT_MIN`, `DIST_PORT_MAX` | `9100` | distribution port, fixed for network policies |
| `POD_IP` / `NODE_IP` | unset | routable address for the node name; Kubernetes sets `POD_IP` from the downward API |
