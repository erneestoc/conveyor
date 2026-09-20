# Configuration reference

Every setting is an environment variable read when the release boots
(`config/runtime.exs`). Required variables are marked; everything else has the default
shown.

## Core

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | required | `ecto://user:pass@host/db`; add `?ssl=true` for managed databases |
| `SECRET_KEY_BASE` | required | 64+ random bytes (`mix phx.gen.secret`); signs cookies and sessions |
| `PHX_HOST` | `example.com` | public hostname of the UI, used in links Bazel prints |
| `PORT` | `4000` | HTTP listener |
| `GRPC_PORT` | `1985` | Build Event Service listener |
| `FORCE_SSL` | `false` | redirect HTTP to HTTPS and send HSTS; only behind a layer-7 terminator that sets `x-forwarded-proto` (an ingress or ALB). Leave off behind a layer-4 balancer such as an NLB, which terminates TLS without adding the header. Health paths are never redirected. |
| `POOL_SIZE` | `40` | PostgreSQL connections per node |
| `ECTO_IPV6` | `false` | connect to PostgreSQL over IPv6 |
| `SHUTDOWN_DRAIN_SECONDS` | `30` | how long SIGTERM waits for open streams |
| `METRICS_TOKEN` | unset | when set, `/metrics` requires `Authorization: Bearer <token>` |

## Ingest

| Variable | Default | Meaning |
|---|---|---|
| `BES_INGEST_AUTH` | `api_key` | `none` maps every stream to the `default` project (trusted networks only) |
| `MAX_STREAMS_PER_KEY` | `200` | concurrent streams per API key per node; beyond it `RESOURCE_EXHAUSTED` |
| `MAX_EVENTS_PER_SECOND_PER_KEY` | `5000` | senders above it are slowed, never failed |
| `MAX_LOG_MB` | `256` | log bytes kept per build; the rest is dropped with a marker |
| `INGEST_BATCH_MAX_EVENTS` | `500` | events per commit batch |
| `INGEST_BATCH_FLUSH_MS` | `50` | batch age before commit |
| `INGEST_WRITER_SHARDS` | schedulers | parallel group-commit writers |
| `INGEST_WRITER_FLUSH_MS` | `20` | group commit interval |
| `INGEST_TAG_FLUSH_MS` | `1000` | tag facet count write interval |
| `INGEST_MAX_UNACKED_EVENTS` | see config | backpressure threshold per stream |
| `INGEST_IDLE_TIMEOUT_MS` | `600000` | a silent stream is marked disconnected after this |
| `INGEST_LINGER_MS` | `30000` | how long a finished build's worker waits for late lifecycle events |

## Retention

| Variable | Default | Meaning |
|---|---|---|
| `RETENTION_DAYS` | `90` | builds older than this are deleted nightly, with their targets, tests, actions and metrics |
| `RETENTION_RAW_DAYS` | `14` | raw event and log segments are dropped by daily partition after this |
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
| `S3_PREFIX` | `blobs` | key prefix |
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
