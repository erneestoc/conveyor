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

## Provability: golden data, properties, contract tests, mutation checks

- **Golden data.** `Conveyor.GoldenData` (test/support) is a hand-written dataset whose
  dashboard numbers are computed by hand in the moduledoc of
  `test/conveyor/metrics/golden_test.exs` and asserted exactly. Extend it rather than
  seeding random data when a new panel needs exact expectations.
- **Two nodes in one test.** `test/conveyor/ingest/two_node_test.exs` starts a second
  `Conveyor.Ingest.Supervisor` (its own registry and worker supervisor, sharing the
  writers) against the same database, streams a build to instance A, resumes it on B while
  A's worker is alive, and checks that A is fenced, B completes and the oracle passes.
- **Properties.** `test/conveyor/ingest/property_test.exs` (StreamData): the normalizer's
  log bytes/lines/text for any sequence of progress events, with and without a log cap,
  and the writer's cross-batch merge of target rows equalling sequential application with
  one row per key.
- **Contract tests on demand.** Excluded by default (`ExUnit.start(exclude: [:s3])`):

  ```sh
  # any S3-compatible store; MinIO locally:
  S3_TEST_BUCKET=conveyor-test S3_TEST_ENDPOINT=http://localhost:9000 S3_TEST_PATH_STYLE=true \
    AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... mix test --only s3
  ```

  OIDC against a real provider is a manual check for now (`AUTH_MODE=oidc` with the
  provider's issuer and client, sign in through the browser); the fake provider covers the
  flow in CI.

### Mutation spot checks

Break one guarantee at a time and the named test must fail; restore the file afterwards.
Verified 2026-09-19 (each mutation applied alone, listed tests run, file restored):

| Guarantee | Mutation | Must fail |
|---|---|---|
| Fenced commits | `lib/conveyor/ingest/writer.ex`, `update_invocation!/1`: drop `and i.last_event_seq == ^expected` from the `where` | `writer_test` "commits a group of batches and notifies each submitter; fenced batches fail alone", `worker_test` "a fenced worker fails its stream", `two_node_test` |
| Acks only after commit | `lib/conveyor/ingest/worker.ex`, `handle_call({:push, …})`, `true ->` branch: add `send(acker, {:ack, seq})` before `absorb/2` | `worker_test` "deduplicates resent events, rejects gaps, and rehydrates after a restart" and "a fenced worker fails its stream" |
| Scrubbing | `lib/conveyor/ingest/scrub.ex`: replace the `@env_re` `Regex.replace` step with `Function.identity/1` | `scrub_test` "redacts credential-like environment variables Bazel copies into the command line" |
| Dedup of resent events | `lib/conveyor/ingest/worker.ex`, `seq < state.expected_seq ->` branch: reply `{:error, :out_of_order}` instead of acking | `worker_test` "deduplicates resent events, rejects gaps, and rehydrates after a restart", `ingest_end_to_end_test` "replayed builds are persisted exactly once, including after a dropped connection" |
