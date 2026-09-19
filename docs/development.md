# Development

Requirements: Elixir 1.20 / OTP 29, Node 20+ (log-engine tests), Docker for PostgreSQL,
`protoc` and `protoc-gen-elixir` only when changing the vendored protos.

```sh
docker compose -f docker-compose.dev.yml up -d   # PostgreSQL on 127.0.0.1:5440
mix setup
PORT=4000 mix phx.server
mix conveyor.seed --replay 1500 --days 30 --big-log 50   # realistic data to browse
```

## Layout

```
lib/conveyor/          domain: ingest pipeline, invocations, query language, metrics, artifacts, accounts
lib/conveyor_grpc/     gRPC endpoint, auth interceptor, PublishBuildEvent, ByteStream/CAS sink
lib/conveyor_web/      Phoenix LiveView UI, controllers, telemetry
lib/conveyor_proto/    generated protobuf modules (Bazel 9.2, googleapis, remote-apis)
assets/js/             LiveView hooks, log engine (log_core.mjs) and workers
priv/protos/           vendored .proto files + gen.sh
deploy/                helm chart, kubernetes manifests, aws-asg terraform, grafana
test/fixtures/bep/     recorded builds used by tests, the replayer, the seed and the load generator
```

## Commands

| Command | Purpose |
|---|---|
| `mix precommit` | the CI gate: compile with warnings as errors, format, sobelow, dependency audit, Node tests, 95 % coverage |
| `mix conveyor.replay FILES --repeat N --concurrency C --drop-after N --verify` | replay fixtures with chaos and the persistence oracle |
| `mix conveyor.loadgen --streams 200 --builds 2000 --retries 5 --verify` | load generator; also the `bes_loadgen` escript (`mix escript.build`) for remote hosts |
| `mix conveyor.seed --replay N --days D --big-log MB` | realistic browsing data through the real pipeline |
| `mix conveyor.e2e_check --bazel 9.2.0` | verify a real Bazel run landed (used by the e2e workflow) |
| `priv/protos/gen.sh` | regenerate protobuf modules after changing `priv/protos/` |

## Testing conventions

- Unit tests are async. Anything touching ingest workers or writers uses
  `Conveyor.IngestCase` (shared sandbox, gRPC on a random port) or `ConveyorWeb.LiveCase`
  (`ingest_fixture!/2` pushes a recorded build through the real pipeline).
- Query tests compare SQL and in-memory evaluation for every operator; keep both in sync.
- LiveView tests assert on element ids; stream containers need ids on every child.
- The log engine has Node tests in `assets/test`; they run inside `mix precommit`.
- CI runs the gate on every push and a real `bazel test` with Bazel 7, 8 and 9 against a
  server started from the checkout.

`HANDOFF.md` in the repository is the running notebook for contributors: conventions,
gotchas, measurements and what to build next. `PLAN.md` is the roadmap with per-milestone
implementation notes.
