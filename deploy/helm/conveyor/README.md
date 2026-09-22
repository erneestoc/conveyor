# Conveyor Helm chart

Installs [Conveyor](https://erneestoc.github.io/conveyor/), a self-hosted Bazel Build
Event Service server with a real-time UI, on an existing Kubernetes cluster. You bring
PostgreSQL (a managed instance such as RDS or Cloud SQL is the expected choice) and, for
more than one replica, an S3-compatible bucket.

```
oci://ghcr.io/erneestoc/charts/conveyor        # published on version tags
```

## Quick install

```sh
kubectl create namespace conveyor
kubectl -n conveyor create secret generic conveyor \
  --from-literal=DATABASE_URL=ecto://user:pass@postgres.example/conveyor \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  --from-literal=RELEASE_COOKIE="$(openssl rand -base64 32)" \
  --from-literal=ADMIN_TOKEN="$(openssl rand -hex 16)"

helm install conveyor oci://ghcr.io/erneestoc/charts/conveyor -n conveyor \
  --set existingSecret=conveyor \
  --set hosts.web=conveyor.example.com --set hosts.grpc=bes.example.com \
  --set config.S3_BUCKET=my-conveyor-blobs --set config.S3_REGION=us-east-1
```

Open `https://conveyor.example.com`, unlock Settings with the admin token, create a
project and an API key, and point Bazel at it:

```
build --bes_backend=grpcs://bes.example.com:443 --bes_header=x-api-key=conveyor_…
build --bes_results_url=https://conveyor.example.com/invocation/
```

## What the chart creates

| Object | Purpose |
|---|---|
| Deployment | the release image; SIGTERM drains open streams before the pod stops |
| Service (ClusterIP) + headless Service | HTTP `4000`, gRPC `1985`; the headless one forms the Erlang cluster (`cluster.enabled`) |
| Ingress × 2 | UI host and gRPC host; separate hosts keep HTTP/2 end to end for Bazel |
| ConfigMap | every `config.*` value as an environment variable |
| Secret | `secrets.*` (or your `existingSecret`) |
| ServiceAccount | annotate for IRSA / workload identity to reach the bucket without keys |
| HPA, PodDisruptionBudget | scaling and availability during node maintenance |
| PVC (optional) | disk blob store for single-replica installs |
| ServiceMonitor, PrometheusRule (optional) | Prometheus Operator scraping and the alert rules in `files/alerts.yml` |

## Values

| Key | Default | Meaning |
|---|---|---|
| `image.repository` / `image.tag` / `image.pullPolicy` | `ghcr.io/erneestoc/conveyor` / chart `appVersion` / `IfNotPresent` | the release image |
| `imagePullSecrets` | `[]` | for a private registry mirror |
| `replicaCount` | `3` | used only when `autoscaling.enabled` is false |
| `hosts.web`, `hosts.grpc` | `conveyor.example.com`, `bes.example.com` | UI and BES hostnames; `PHX_HOST` follows `hosts.web` |
| `config.AUTH_MODE` | `open` | `open` (everyone reads, `ADMIN_TOKEN` unlocks Settings) or `oidc` |
| `config.OIDC_*` | unset | `OIDC_CLIENT_ID`, `OIDC_ISSUER`, `OIDC_SCOPES`, `OIDC_GROUPS_CLAIM`, `OIDC_ADMIN_GROUPS`, `ADMIN_EMAILS`, `ALLOWED_EMAIL_DOMAINS`; the client secret goes in the Secret |
| `config.BES_INGEST_AUTH` | `api_key` | `none` accepts unauthenticated streams into the default project (trusted networks only) |
| `config.CAS_SINK_ENABLED` | `"true"` | accept Bazel's `--remote_cache` uploads of profiles and test outputs |
| `config.BLOB_STORE` | `s3` | `s3` for any replica count; `disk` only with `replicaCount: 1` and `persistence.enabled` |
| `config.S3_BUCKET`, `config.S3_REGION`, `config.S3_ENDPOINT`, `config.S3_PREFIX` | bucket, `us-east-1`, unset, `blobs` | S3-compatible stores (MinIO, R2) set `S3_ENDPOINT` and `S3_PATH_STYLE=true`; each project stores under `<S3_PREFIX>/<project prefix>/` |
| `config.DATABASE_SSL`, `config.DATABASE_SSL_CA` | unset | `"true"` verifies PostgreSQL's certificate; point `DATABASE_SSL_CA` at a bundle mounted with `extraVolumes` |
| `config.RETENTION_DAYS`, `config.RETENTION_RAW_DAYS` | `"90"`, `"14"` | builds and raw event/log segments; projects can shorten retention in Settings |
| `config.POOL_SIZE` | `"40"` | PostgreSQL connections per pod; `max_connections` ≥ pods × pool + 20 |
| `config.MAX_STREAMS_PER_KEY`, `config.MAX_EVENTS_PER_SECOND_PER_KEY`, `config.MAX_LOG_MB` | `"500"`, `"5000"`, `"256"` | per-key limits (per pod) |
| `config.SHUTDOWN_DRAIN_SECONDS` | `"45"` | must be below `terminationGracePeriodSeconds` and the ingress' backend timeout |
| `config.FORCE_SSL` | `"false"` | `"true"` redirects HTTP to HTTPS and sends HSTS; the ingress must set `x-forwarded-proto` |
| `config.METRICS_TOKEN` | unset | bearer token for `/metrics`; without it an admin session is required |
| `secrets.*` | `{}` | rendered into a Secret: `DATABASE_URL`, `SECRET_KEY_BASE`, `RELEASE_COOKIE`, `ADMIN_TOKEN`, `OIDC_CLIENT_SECRET`, `METRICS_TOKEN`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| `existingSecret` | `""` | use a Secret you manage (External Secrets, SOPS) instead of `secrets.*` |
| `cluster.enabled`, `cluster.nodeBasename` | `true`, `conveyor` | Erlang clustering through the headless service (no RBAC); carries PubSub and cache invalidation only, never ingest correctness |
| `persistence.enabled`, `.size`, `.storageClass` | `false`, `50Gi`, `""` | PVC for `BLOB_STORE=disk` |
| `service.type`, `service.annotations` | `ClusterIP`, `{}` | |
| `ingress.className` | `nginx` | |
| `ingress.web.enabled`, `.annotations`, `.tls` | `true`, cert-manager issuer, `true` | the UI |
| `ingress.grpc.enabled`, `.annotations`, `.tls` | `true`, cert-manager issuer + `backend-protocol: GRPC` + long read timeout, `true` | the BES endpoint; keep the gRPC annotations for your controller |
| `resources` | requests 1 vCPU / 1 GiB, limits 4 / 4 GiB | about 1 MB per concurrent build plus 150 MB base |
| `autoscaling.enabled`, `.minReplicas`, `.maxReplicas`, `.targetCPUUtilizationPercentage` | `true`, `3`, `12`, `60` | scale-in is one pod per two minutes so streams drain |
| `podDisruptionBudget.enabled`, `.minAvailable` | `true`, `2` | |
| `metrics.annotations` | `true` | `prometheus.io/scrape` pod annotations |
| `metrics.serviceMonitor.enabled`, `.interval` | `false`, `30s` | Prometheus Operator |
| `metrics.prometheusRule.enabled`, `.labels` | `false`, `{}` | the alert rules (`files/alerts.yml`, a copy of `deploy/prometheus/alerts.yml`) |
| `serviceAccount.create`, `.name`, `.annotations` | `true`, `""`, `{}` | annotate with `eks.amazonaws.com/role-arn` (IRSA) or `iam.gke.io/gcp-service-account` |
| `terminationGracePeriodSeconds` | `60` | |
| `extraEnv`, `extraVolumes`, `extraVolumeMounts` | `[]` | anything else |
| `podAnnotations`, `podLabels`, `nodeSelector`, `tolerations`, `affinity` | `{}` / `[]` | |

Every `config.*` key is a Conveyor environment variable; the full list with defaults is in
the [configuration reference](https://erneestoc.github.io/conveyor/configuration/).

## Sign-in with OpenID Connect

```yaml
config:
  AUTH_MODE: oidc
  OIDC_CLIENT_ID: conveyor
  OIDC_ISSUER: https://login.example.com/realms/eng
  OIDC_SCOPES: openid email profile groups
  OIDC_ADMIN_GROUPS: platform-admins
  ALLOWED_EMAIL_DOMAINS: example.com
secrets:
  OIDC_CLIENT_SECRET: "…"
```

Redirect URI: `https://<hosts.web>/auth/oidc/callback`. Groups in the ID token drive
per-project visibility and project admins (set in Settings). Details:
[Sign-in and access](https://erneestoc.github.io/conveyor/auth/).

## Blob storage credentials

On EKS, annotate the service account with an IAM role that may `GetObject`, `PutObject`,
`DeleteObject` and `ListBucket` on the bucket, and set no AWS keys. Elsewhere put
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in the Secret (`S3_ENDPOINT` +
`S3_PATH_STYLE=true` for MinIO, Ceph or R2). A single replica can use `BLOB_STORE=disk`
with `persistence.enabled`.

## Database TLS

```sh
kubectl -n conveyor create configmap rds-ca --from-file=rds-ca.pem=global-bundle.pem
```

```yaml
config:
  DATABASE_SSL: "true"
  DATABASE_SSL_CA: /etc/conveyor/rds-ca.pem
extraVolumes:
  - name: rds-ca
    configMap: { name: rds-ca }
extraVolumeMounts:
  - name: rds-ca
    mountPath: /etc/conveyor
    readOnly: true
```

## Upgrades and rollouts

Migrations run at boot; a new pod becomes ready only after they succeeded. Rolling
updates surge one pod at a time with zero unavailable: a pod that receives SIGTERM turns
not-ready, refuses new streams, and drains open ones for `SHUTDOWN_DRAIN_SECONDS`. Bazel
retries a stream that was cut on another pod and resumes from the last acknowledged event
(`--build_event_upload_max_retries=10` recommended). `helm upgrade` with a new chart
version and the same values is enough; read `CHANGELOG.md` for application changes.

## Uninstall

`helm uninstall conveyor -n conveyor` removes everything but the PVC (if any), the
Secret you created and your database and bucket.
