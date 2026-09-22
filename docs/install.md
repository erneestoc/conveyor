# Install

Three ways to run Conveyor, each ending with a working Bazel command. Pick the one that
matches where your builds run; the [configuration reference](configuration.md) has every
variable and the [production guide](production.md) the reasoning.

## One box with Docker Compose

For a team or a trial. PostgreSQL and Conveyor on one host, blobs on a volume.

```sh
git clone https://github.com/erneestoc/conveyor && cd conveyor
sed -i 's/change-me-to-64-random-bytes.*/'"$(openssl rand -base64 48)"'/; s/ADMIN_TOKEN: change-me/ADMIN_TOKEN: '"$(openssl rand -hex 16)"'/' docker-compose.yml
docker compose up -d
```

Open `http://localhost:4000`, unlock Settings with the admin token, create a project and
an API key, then:

```sh
bazel test //... --bes_backend=grpc://localhost:1985 \
  --bes_results_url=http://localhost:4000/invocation/ \
  --bes_header=x-api-key=conveyor_…
```

To serve other machines put Caddy (or any TLS proxy) in front: `reverse_proxy
127.0.0.1:4000` for the UI and, on port 1985, `reverse_proxy h2c://127.0.0.1:1986` with
Conveyor on `GRPC_PORT=1986`; then Bazel uses `grpcs://` and `--bes_results_url=https://…`.

## EC2 with a Caddy edge or a Network Load Balancer

`deploy/trial` is a complete Terraform stack: an auto-scaling group of arm64 nodes running
the release image, RDS PostgreSQL with TLS, an S3 blob bucket, and either a single node
with a Caddy sidecar (Let's Encrypt, Elastic IP) or several nodes behind an NLB with an
ACM certificate. Copy it, set `conveyor_host` and `zone_id`, and:

```sh
cd deploy/trial && terraform init && terraform apply -var conveyor_count=0   # database, bucket, registry
docker buildx build --platform linux/arm64 -t $(terraform output -raw ecr_conveyor):trial --push ../..
terraform apply                                                              # nodes
```

Sign in with `terraform output -raw admin_token`, create a project and a key, and point
Bazel at `grpcs://<host>:1985`. The shapes, cost and the restore-from-snapshot variable
are in `deploy/trial/README.md`; `deploy/aws-asg` is the same idea without NativeLink and
the builder tasks.

## Kubernetes with Helm

```sh
kubectl create namespace conveyor
kubectl -n conveyor create secret generic conveyor \
  --from-literal=DATABASE_URL=ecto://user:pass@postgres.internal/conveyor \
  --from-literal=SECRET_KEY_BASE=$(openssl rand -base64 48) \
  --from-literal=RELEASE_COOKIE=$(openssl rand -hex 20) \
  --from-literal=ADMIN_TOKEN=$(openssl rand -hex 16)
helm install conveyor oci://ghcr.io/erneestoc/charts/conveyor -n conveyor \
  --set existingSecret=conveyor \
  --set hosts.web=conveyor.example.com --set hosts.grpc=bes.example.com \
  --set config.S3_BUCKET=conveyor-blobs --set config.S3_REGION=us-east-1
```

The chart creates two ingresses (UI and gRPC with the nginx gRPC backend protocol and
cert-manager annotations), a headless service for clustering, an HPA, a PDB, and
optional ServiceMonitor and PrometheusRule. Bazel points at `grpcs://bes.example.com:443`.
Details, OIDC and S3 credentials are in [Kubernetes and Helm](kubernetes.md).

## After any install

- Put the Bazel flags in `.bazelrc` ([Configure Bazel](bazel.md)); CI systems get their own
  key with default tags ([Conveyor in CI](ci.md)).
- Set `AUTH_MODE=oidc` for people ([Sign-in and access](auth.md)); keep the admin token
  only for bootstrap.
- Wire `/metrics` into Prometheus and load `deploy/prometheus/alerts.yml`
  ([Operations](operations.md)).
- Size the database for sustained ingest, not bursts ([Capacity](capacity.md)).
