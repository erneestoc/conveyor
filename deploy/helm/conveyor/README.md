# Conveyor Helm chart

Installs Conveyor on an existing Kubernetes cluster. You bring PostgreSQL and, for more
than one replica, an S3-compatible bucket.

```sh
kubectl create namespace conveyor
kubectl -n conveyor create secret generic conveyor \
  --from-literal=DATABASE_URL=ecto://user:pass@postgres.example/conveyor \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  --from-literal=RELEASE_COOKIE="$(openssl rand -base64 32)" \
  --from-literal=ADMIN_TOKEN="$(openssl rand -hex 16)"

helm install conveyor deploy/helm/conveyor -n conveyor \
  --set existingSecret=conveyor \
  --set hosts.web=conveyor.example.com --set hosts.grpc=bes.example.com \
  --set config.S3_BUCKET=my-conveyor-blobs --set config.S3_REGION=us-east-1
```

Then open `https://conveyor.example.com`, sign in with the admin token, create a project
and an API key in Settings, and point Bazel at `grpcs://bes.example.com:443`.

## Values

| Key | Default | Notes |
|---|---|---|
| `image.repository`, `image.tag` | `ghcr.io/example/conveyor`, chart `appVersion` | |
| `replicaCount` | 3 | ignored when `autoscaling.enabled` |
| `hosts.web`, `hosts.grpc` | example hosts | separate hosts keep HTTP/2 end to end for gRPC |
| `config.*` | see `values.yaml` | every Conveyor environment variable; rendered into a ConfigMap |
| `secrets.*` / `existingSecret` | `{}` / `""` | `DATABASE_URL`, `SECRET_KEY_BASE`, `RELEASE_COOKIE`, `ADMIN_TOKEN`, `OIDC_CLIENT_SECRET`, `METRICS_TOKEN`, AWS keys |
| `cluster.enabled` | true | Erlang clustering through a headless service; no RBAC needed |
| `persistence.enabled` | false | disk blob store on a PVC for single-replica installs (`config.BLOB_STORE=disk`) |
| `ingress.web`, `ingress.grpc` | ingress-nginx + cert-manager | the gRPC ingress needs the `backend-protocol: GRPC` annotation |
| `autoscaling` | 3 to 12 pods at 60 % CPU | scale-in one pod per two minutes so streams drain |
| `podDisruptionBudget.minAvailable` | 2 | |
| `resources` | 1 vCPU / 1 GiB requested, 4 / 4 GiB limit | about 1 MB per concurrent build |
| `metrics.serviceMonitor.enabled` | false | Prometheus Operator |

Rolling updates: a pod that receives SIGTERM reports not-ready, refuses new streams with
UNAVAILABLE (Bazel retries on another pod) and waits `SHUTDOWN_DRAIN_SECONDS` for open
streams; `terminationGracePeriodSeconds` must exceed that. Migrations run on boot and
are safe alongside older pods.
