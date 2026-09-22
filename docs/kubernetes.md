# Kubernetes and Helm

The Helm chart in `deploy/helm/conveyor` installs Conveyor on an existing cluster. You
bring PostgreSQL and, for more than one replica, an S3-compatible bucket. Plain manifests
for the same layout are in `deploy/kubernetes`, and an EC2 auto-scaling group in
`deploy/aws-asg` (Terraform).

## Install

```sh
kubectl create namespace conveyor
kubectl -n conveyor create secret generic conveyor \
  --from-literal=DATABASE_URL=ecto://user:pass@postgres.example/conveyor \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  --from-literal=RELEASE_COOKIE="$(openssl rand -base64 32)" \
  --from-literal=ADMIN_TOKEN="$(openssl rand -hex 16)"

helm install conveyor oci://ghcr.io/erneestoc/charts/conveyor --version 0.2.0 -n conveyor \
  --set existingSecret=conveyor \
  --set hosts.web=conveyor.example.com --set hosts.grpc=bes.example.com \
  --set config.S3_BUCKET=my-conveyor-blobs --set config.S3_REGION=us-east-1
```

Open `https://conveyor.example.com`, sign in with the admin token, create a project and
an API key in Settings, and point Bazel at `grpcs://bes.example.com:443`.

## What the chart creates

| Object | Purpose |
|---|---|
| Deployment | the release image, non-root, readiness on `/health/ready`, liveness on `/health/live`, a 5 s `preStop` so endpoints update before the drain starts |
| Service + headless Service | HTTP and gRPC ports; the headless service is how nodes find each other (libcluster DNS, no RBAC) |
| ConfigMap, Secret | every Conveyor setting is an environment variable; `config` and `secrets` in values map straight onto them |
| Two Ingresses | the UI host and the gRPC host; gRPC needs HTTP/2 end to end, hence the `backend-protocol: GRPC` annotation for ingress-nginx and a long read timeout for streams |
| HorizontalPodAutoscaler | 3 to 12 pods at 60 % CPU, scaling in one pod per two minutes so open streams drain |
| PodDisruptionBudget | at least two pods during node maintenance |
| PersistentVolumeClaim (optional) | disk blob store for a single-replica install without S3 |
| ServiceMonitor (optional) | Prometheus Operator scraping of `/metrics` |
| PrometheusRule (optional) | the alert rules of `deploy/prometheus/alerts.yml` (`metrics.prometheusRule.enabled`) |

## Values you will set

- `hosts.web`, `hosts.grpc`: the two public hostnames.
- `secrets.*` or `existingSecret`: `DATABASE_URL`, `SECRET_KEY_BASE`, `RELEASE_COOKIE`,
  `ADMIN_TOKEN` or `OIDC_CLIENT_SECRET`, optionally `METRICS_TOKEN` and AWS keys (omit
  the keys with IRSA or an instance role).
- `config.*`: `AUTH_MODE` and the OIDC variables ([Sign-in and access](auth.md)),
  `S3_BUCKET`/`S3_REGION`, retention, limits, `POOL_SIZE`. The full list is in the
  [configuration reference](configuration.md).
- `resources`, `autoscaling`: size from the [production guide](production.md); about
  1 MB per concurrent build plus 150 MB, CPU scales with events per second.

## Rolling updates and scale-in

A pod that receives SIGTERM reports not-ready, refuses new streams with `UNAVAILABLE`
(Bazel retries another pod), waits up to `SHUTDOWN_DRAIN_SECONDS` (45 in the chart) for
open streams, then exits. `terminationGracePeriodSeconds` (60) must exceed the drain.
Builds still streaming when the pod exits resume on another pod from their last
committed event. Migrations run on boot and are additive, so old and new pods coexist
during the rollout.

## Ingress notes

- **ingress-nginx**: shown in the chart. Set `proxy-read-timeout` above your longest
  build; a stream is one long HTTP/2 request.
- **AWS ALB**: use a gRPC target group (`alb.ingress.kubernetes.io/backend-protocol-version: GRPC`)
  and an idle timeout above the longest build.
- **Envoy / Istio**: HTTP/2 to the backend is the default; nothing special.
- TLS terminates at the ingress; set `FORCE_SSL=true` if the UI host should redirect and
  send HSTS.

## Docker Compose

`docker-compose.yml` at the repository root runs one node with PostgreSQL and the disk
blob store, for trials and small teams. The published image is
`ghcr.io/erneestoc/conveyor:<version>` (multi-arch, non-root); it runs migrations on boot.

## Publishing the chart

Version tags (`v*`) run `.github/workflows/release.yml`, which builds the multi-arch image
to `ghcr.io/erneestoc/conveyor`, packages the chart with the tag as chart and app version
and pushes it to `oci://ghcr.io/erneestoc/charts/conveyor`, then pushes the Artifact Hub
repository metadata (`deploy/helm/artifacthub-repo.yml`) next to it with `oras`. Once,
after the first release:

1. Make the `charts/conveyor` and `conveyor` packages public in the GitHub package
   settings (GHCR packages start private).
2. On [artifacthub.io](https://artifacthub.io), Control panel → Add repository → kind
   *Helm charts*, URL `oci://ghcr.io/erneestoc/charts/conveyor`. Artifact Hub indexes
   OCI charts by tag; the chart's `annotations` (license, links, changes) render on its
   page.
3. Copy the repository ID Artifact Hub shows into `artifacthub-repo.yml` to claim the
   verified-publisher badge; the next release pushes it.

The chart's README (`deploy/helm/conveyor/README.md`) documents every value, OIDC, S3
credentials, database TLS and upgrades.

