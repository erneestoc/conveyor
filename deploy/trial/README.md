# Conveyor trial on AWS

A complete, tear-down-able environment for exercising Conveyor with real open-source Bazel
builds: Conveyor behind a TLS load balancer, RDS PostgreSQL, S3 blobs, a self-hosted
[NativeLink](https://github.com/TraceMachina/nativelink) remote cache and remote executor
with a private CA, and ECS Fargate tasks that clone projects and stream builds in.

```
conveyor.algobien.com  ──NLB (TLS, ACM)──►  Conveyor ASG (arm64) ──► RDS PostgreSQL, S3
cache.rbe.algobien.com ──TLS (private CA)──► NativeLink CAS + scheduler (one instance)
rbe.algobien.com                             └── worker ASG (amd64, same toolchains as the builders)
ECS Fargate "builder" tasks ── bazel --bes_backend=grpcs://conveyor… --remote_cache/--remote_executor=grpcs://…rbe…
```

## Shapes

- **Staging (default):** `edge = "caddy"`, one `t4g.medium` node with a Caddy sidecar that
  terminates TLS itself (Let's Encrypt for the UI on 443 and gRPC/h2 on 1985), an Elastic
  IP the node claims at boot and DNS pointing at it; no balancer. About $2.30/day with the
  `db.t3.micro`. Caddy keeps its certificate in a Docker volume on the instance, so an
  instance refresh re-issues it (Let's Encrypt allows five per week for the same name).
- **Soak / multi-node:** `-var edge=nlb -var conveyor_count=2` puts the nodes behind the
  Network Load Balancer with the ACM certificate. Switching shapes changes DNS and rolls
  the nodes (a few minutes of unavailability).
- **Restore from a backup:** `-var db_snapshot_identifier=<snapshot>` builds the database
  from an RDS snapshot (a fresh stack) — on an existing stack it *replaces* the database.

The nodes connect to RDS with `DATABASE_SSL=true` and the AWS global bundle downloaded at
boot; `rds.force_ssl` is on.

## Bring-up

```sh
export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
cd deploy/trial
terraform init
terraform apply -var conveyor_count=0 -var nl_workers=0        # registry, database, balancer, certificate (~12 min)

# Images (built on the laptop; the Conveyor nodes are arm64, builders and workers amd64)
ECR=$(terraform output -raw ecr_conveyor | cut -d/ -f1)
aws ecr get-login-password | docker login --username AWS --password-stdin $ECR
(cd ../.. && docker buildx build --platform linux/arm64 -t $(terraform -chdir=deploy/trial output -raw ecr_conveyor):trial --push .)
docker buildx build --platform linux/amd64 --target builder   -t $(terraform output -raw ecr_builder):latest   --push images
docker buildx build --platform linux/amd64 --target nl-worker -t $(terraform output -raw ecr_nl_worker):latest --push images

terraform apply                                                 # nodes and workers
./bootstrap.sh                                                  # API key + NativeLink cache endpoint in Conveyor, key into SSM
```

Sign in at `https://conveyor.algobien.com/auth/login` with `terraform output -raw admin_token`.

## Running builds

`projects.json` lists the projects (repo, optional subdirectory, build and test targets).
`runner.py` starts one Fargate task per project × mode × repetition; each task runs the
workload steps in one Bazel output base and tags every invocation with `repo`, `mode`,
`workload`, `wave`, `commit`, `ci=true`:

```sh
./runner.py run --projects fixture,cpp-tutorial --modes local,cache,rbe --wave smoke --wait
./runner.py run --projects abseil,protobuf,buildtools,nativelink --modes cache,rbe --wave w1 --repeat 3
./runner.py list
./runner.py logs <task-arn>
```

Workload steps (`--workload`, default `clean,noop,leaf,wide,buildfile,test`): a clean build,
a no-change rebuild, a leaf source edit, an edit to the most widely referenced source file,
a BUILD file edit, then the tests. Modes: `local` (no remote), `cache` (NativeLink as
`--remote_cache`), `rbe` (plus `--remote_executor`). Every build carries
`--execution_log_compact_file` and `--profile`; the execution log is uploaded through the
artifact API after each build, the profile is referenced through the remote cache (and
fetched by Conveyor through the cache endpoint with the private CA) or uploaded directly in
`local` mode.

## Tear-down

```sh
terraform apply -var rbe_enabled=true -var nl_workers=4          # bring NativeLink up (off by default)
terraform destroy                                               # everything (RDS without a final snapshot)
```

Secrets live in Terraform state (S3 bucket `conveyor-trial-tfstate-<account>`) and SSM
Parameter Store under `/conveyor-trial/`. Instances have no SSH; use SSM Session Manager.
