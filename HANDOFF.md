# Conveyor — session handoff

Read this first when resuming work. It captures everything that is not obvious from the
code: state, conventions, gotchas, and exactly what to build next. `PLAN.md` is the full
roadmap (§21 has per-milestone implementation notes); this file is the operational summary.

## 1. What Conveyor is

A self-hosted Bazel Build Event Service (BES) server with a Phoenix LiveView UI, MIT licensed.
Bazel clients point `--bes_backend` at the gRPC endpoint; every build appears live with its
log, timeline, targets, tests, metrics, and free-form tags from `--build_metadata`, plus a
dashboard (success rate, p50/p90/p99 per segment, cache hit rate, failures, tests).

Stack: Elixir 1.20 / OTP 29, Phoenix 1.8 + LiveView 1.2, PostgreSQL 17 (dev container),
elixir-grpc 1.0 (`grpc_server` + `grpc`, Cowboy adapter), `protobuf` 0.17, Oban 2.24,
excoveralls, Tailwind v4 (daisyUI plugin present but app components are hand-written).

## 2. Working agreements with the user (do not relitigate)

- Project name is **Conveyor** (modules `Conveyor.*`, `ConveyorWeb.*`).
- **Commit per step**, never push. Attribution trailer on every commit:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- **95%+ line coverage is a hard gate**: `mix precommit` = compile --warnings-as-errors,
  deps.unlock --unused, format, `coveralls` with `minimum_coverage: 95` (`coveralls.json`
  excludes `lib/conveyor_proto/`, `test/support/`, release/telemetry boilerplate).
  **Gotcha:** `mix precommit | grep ...` hides the exit code. Run
  `mix precommit > log 2>&1; echo $?` and only commit on 0.
- Act autonomously; ask only for real product decisions (see §8).
- Multi-node (Kubernetes + EC2 ASG) is in scope (M7). Load testing is a first-class deliverable.
- Routes: `/invocation/:id/:tab` is a LiveView catch-all, so any new 3-segment path under `/invocation/:id/` must go under `/download/…` or `/artifact/…` (a `get` declared after it is shadowed).
- Blob store in dev writes to `tmp/blobs_dev` (test: `tmp/blobs_test`, both git-ignored); `CAS_SINK_ENABLED` is on in dev config.
- Original implementation only: do not read BuildBuddy or other BES implementations' source.

## 3. Status (2026-09-19): commits on `main`

| Commit | Milestone | Content |
|---|---|---|
| M0 | Bootstrap + spike | Phoenix app, vendored protos + `priv/protos/gen.sh`, gRPC `PublishBuildEvent` server, 7 recorded fixtures, `Conveyor.Bep.{Fixture,Replay}`, `mix conveyor.replay` |
| M1 | Ingest + persistence | Projects, API keys, auth interceptor, `IngestWorker`, `Normalizer`, `Scrub`, `Tags`, `Writer` pool (group commit + CAS fencing), segments in daily partitions, Oban maintenance, `Verify` oracle, retries + pool tuning |
| M2 | UI | App shell, `BuildsLive`, `InvocationLive` (overview/log/targets/tests/actions/details/events), log viewer hook, download controller |
| M3 | Query language | `Conveyor.Query` (parser, Ecto compiler, in-memory evaluator), facets, search UI |
| M4 | Dashboard | `Conveyor.Metrics.{Scope,Dashboard,Tests}`, `DashboardLive`, `TestsLive`, SVG charts, Metrics tab, `mix conveyor.seed` |
| M5 | Artifacts + timeline | `Conveyor.Blobs` (Disk/S3), `Conveyor.Artifacts` (+ `Resource`, `BytestreamClient`, `Junit`), gRPC `ByteStreamServer`/`CasServer`/`CapabilitiesServer`/`ActionCacheServer` (CAS sink), `UploadController` + `Plugs.ApiAuth` + `tools/bes-upload-profile`, `Conveyor.Profile` + `Workers.{FetchProfile,ProfileSummary,BlobMaintenance}`, canvas profile timeline (`assets/js/hooks/profile_timeline.js`, `assets/js/profile_worker.js`), test.log/test.xml viewer, cache endpoints in Settings |
| M6 | Auth + security | `Conveyor.Accounts` (+ `User`, `Scope`), `ConveyorWeb.Plugs.Auth`, `ConveyorWeb.Auth` (on_mount), `AuthController`/`AuthHTML` (OIDC via assent, admin token), `Conveyor.Audit`, `Conveyor.Limits`, `Plugs.SecurityHeaders` (nonce CSP), sobelow + deps.audit in precommit, `.github/workflows/ci.yml`, `docs/security.md`, settings: allowed groups + audit log |

197 tests, 95.8% coverage. Verified with real Bazel 9.2.0 end to end, including
`--remote_cache=grpc://localhost:1985 --remote_upload_local_results=false --remote_build_event_upload=minimal --noremote_accept_cached`
against the CAS sink (profile, test.log, test.xml uploaded; profile timeline + summary rendered).

## 4. Running things locally

```sh
docker compose -f docker-compose.dev.yml up -d      # Postgres on 127.0.0.1:5440 (user/pass postgres)
mix setup                                           # deps, db create+migrate, assets
PORT=4100 mix phx.server                            # web :4100 (port 4000 is taken by another project on this machine), gRPC :1985
```

- Dev ingest auth is `:none` (everything lands in project `default`); set `BES_INGEST_AUTH=api_key` to require keys.
- Restart flow used all session: `pkill -f "mix phx.server"`, wait until ports 1985/4100 are free, start again. Two servers cannot share the gRPC port.
- Real build: from `test/fixtures/workspace`:
  `bazel test //app:pass_test //lib:greeting --action_env=NONCE=$RANDOM --bes_backend=grpc://localhost:1985 --bes_results_url=http://localhost:4100/invocation/ --build_metadata=USER=$USER --build_metadata=CI=false`
- Replay fixtures (no Bazel needed), with connection-drop chaos and the persistence oracle:
  `mix conveyor.replay test/fixtures/bep/*.bep --repeat 100 --concurrency 200 --drop-after 20 --verify`
- Synthetic dashboard data: `mix conveyor.seed --invocations 5000 --days 30` (starts only the Repo; safe while the server runs).
- Screenshots for design review: `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --screenshot=out.png --window-size=1440,1000 URL` (LiveView JS does not connect in headless screenshots; server-rendered HTML only).
- Test DB: `mix test` migrates automatically. If migrations are edited in place (they were, pre-release), rebuild: `MIX_ENV=test mix do ecto.drop, ecto.create, ecto.migrate` and `mix ecto.reset` for dev.
- Regenerate protobuf modules after changing `priv/protos/`: `priv/protos/gen.sh` (needs `protoc` and `~/.mix/escripts/protoc-gen-elixir`). `google/api`, `google/rpc`, `google/longrunning`, `google/bytestream` messages come from the `googleapis` hex dep and are NOT generated (the ByteStream *service* module is missing from the dep — hand-write a `GRPC.Service` for it when building the CAS sink).

## 5. Code map

```
lib/conveyor/
  bep/event.ex          unwrap BES Any → BEP, kind names, time conversions
  bep/fixture.ex        varint-delimited BEP file reader/writer (same framing as segments)
  bep/replay.ex         Bazel-faithful BES client (lifecycle + stream, drop_after chaos)
  ingest.ex             Context struct, push/3 (async ack via acker pid), push_sync/2 (tests), lifecycle/2, topics
  ingest/worker.ex      per-invocation GenServer: order/dedup, absorb → Normalizer, batches, backpressure (max_unacked_events), idle timeout → disconnected, finalize + linger, PubSub digests
  ingest/normalizer.ex  pure BEP payload → State (inv map + dirty) + Batch rows; finalize/disconnect
  ingest/batch.ex       rows for one commit; event/log segment rows (zstd via :zstd from OTP)
  ingest/writer.ex      group commit per shard, per-batch fallback, Fenced (CAS on last_event_seq), Retry
  ingest/writer_pool.ex shards by phash2(invocation_id)
  ingest/scrub.ex       redacts header flags, URL creds, token=, Bearer in command lines/logs (rewrites raw protobuf)
  ingest/tags.ex        merge order derived < workspace_status < keywords < api_key < build_metadata; ignores volatile keys
  ingest/status.ex      exit code → status, categories
  ingest/retry.ex       backoff for DBConnection/Postgrex transient errors
  ingest/verify.ex      oracle: contiguous segments, counts, log offsets, final status
  invocations.ex        read side: list(project_id/statuses/query/before), events/raw_frames/log/log_segments/targets/test_results/actions/metrics/named_sets/facets/failed_targets/slowest_tests/events_page/day
  invocations/*.ex      schemas (Invocation, Target, TestResult, Action, Metrics, NamedSet, TagKey, EventSegment, LogSegment)
  projects.ex           projects + api keys (create/verify/rotate/revoke/touch/expiring); ApiKeyCache (ETS + PubSub invalidation); Segments defaults
  query.ex, query/parser.ex, query/values.ex   search language
  metrics/{scope,dashboard,tests}.ex           dashboard queries
  storage.ex, storage/partitions.ex            boot-time partition creation, retention drops
  workers/partition_maintenance.ex             Oban hourly cron
lib/conveyor_grpc/      endpoint.ex (interceptors: Logger, AuthInterceptor), auth_interceptor.ex, publish_build_event_server.ex, acker.ex
lib/conveyor_web/       live/{builds,invocation,dashboard,tests,settings}_live.ex, components/{build_components,charts,timeline,layouts,core_components}.ex, controllers/download_controller.ex, format.ex, not_found_error.ex
assets/js/hooks/        live_time.js (ticking durations), log_viewer.js (ANSI + \r/cursor-up emulation, virtualized)
lib/mix/tasks/          conveyor.replay, conveyor.seed
test/support/           data_case, conn_case, grpc_case (random port), ingest_case (shared sandbox + gRPC), live_case (ingest fixtures through the real pipeline)
priv/protos/            vendored Bazel 9.2.0 / googleapis / remote-apis protos (+ LICENSE files, VERSION, gen.sh)
```

## 6. Key design facts to keep intact

- **Acks are the durability boundary.** An event is acked only after its batch commits; Bazel resends from the last un-acked seq; `seq < expected` is acked immediately (dedup); `seq > expected` → FAILED_PRECONDITION.
- **Fencing:** every batch commit does `UPDATE invocations SET ... WHERE last_event_seq = first_seq - 1`; failure = `{:fenced, n}` → worker exits → stream fails → Bazel retries. Works across nodes without cluster locks.
- **Segment partition day = `invocations.inserted_at` date**, never `started_at` (it changes). Partitions `event_segments_YYYYMMDD` / `log_segments_YYYYMMDD` are created on boot (`Conveyor.Storage.boot/0`) and hourly; creation tolerates `duplicate_table` (boot races).
- **Targets are keyed by (label, aspect)**; `configuration_id` is an attribute (TargetConfigured carries no configuration).
- **Tags:** lowercase keys, string values; reserved keys (`status`, `id`, `project`) become `user.<key>`; ignored: build_timestamp, formatted_date, build_embed_label, command_name, protocol_name.
- **API keys:** `conveyor_<8 base32 chars>_<43 base64url>`; sha256 stored; lookup by key_id via ETS (30 s TTL, invalidated locally + via PubSub).
- **Bazel retry budget is short** (default 4 retries ≈ seconds). Docs must recommend `--build_event_upload_max_retries=10`; restarts must be fast; balancers must stop routing before a node drains.
- **Bazel copies the client env into the command line** (`--client_env=NAME=VALUE`), so scrubbing is mandatory; fixtures were scrubbed and history rewritten.
- **Finish lifecycle events must never start a new worker** for a finished build (it did once; worker lived until idle timeout).
- Config knobs live in `config :conveyor, Conveyor.Ingest` (auth, idle_timeout_ms, linger_ms, batch_max_events/bytes, batch_flush_ms, writer_shards, writer_flush_ms, broadcast_interval_ms, max_unacked_events). DB pool: dev 20, prod `POOL_SIZE` default 40, `queue_target 1s / queue_interval 10s` (overload → latency, not errors).

## 7. Next work, in order (with concrete specs)

### M5 — done (see PLAN §21). Follow-ups worth remembering
- `--remote_build_event_upload=minimal` uploads only the profile and test outputs; other BEP files get `bytestream://` URIs that are *not* in the store (the UI shows a hint). `full` would upload everything.
- IMDS/instance-role credentials for S3 are not implemented (static keys + `AWS_SESSION_TOKEN` only); private CAs for cache endpoints (TLS uses the system store).
- Dashboard "where does build time go" aggregation over `profile_summary` (PLAN §10) is not built.
- The Tier B canvas is verified via Node (`build()` + a `worker_threads` simulation of the built bundle) and a headless screenshot of the inline path; headless Chrome does not drive Web Worker fetches under `--virtual-time-budget`, and LiveView never connects headless, so use the `data-inline="true"` trick on a temporary page under `priv/static/assets/` for visual checks.

### M6 — done (see PLAN §21). Follow-ups
- No UI for per-key limit overrides yet (`Projects.update_api_key_limits/2`; defaults via `MAX_STREAMS_PER_KEY`, `MAX_EVENTS_PER_SECOND_PER_KEY`, `MAX_LOG_MB`).
- Limits are per node (ETS); M7 should either accept N× limits across nodes or route by key.
- Okta was not verified against a real tenant (only the fake provider); Keycloak is running locally in Docker (`chumti-keycloak`) if a real-provider check is wanted.
- cowlib EEF-CVE-2026-43969 still open upstream (accepted, see docs/security.md); `mix hex.audit` is informational in CI.

### M7 — scale campaign + multi-node
- `bes_loadgen` escript (built on `Conveyor.Bep.Replay`): streams, builds/min, speed, fixture mix, jitter, chaos (drops, duplicates, server restarts), ack-latency percentiles; `mix conveyor.verify` over a run. Add per-ack latency telemetry (`[:conveyor, :ingest, :ack]`) and Prometheus `/metrics`.
- Targets (§13.1 of PLAN): 1,000 streams, 30k events/s, ack p99 < 250 ms, zero loss through restart storm and DB restart. Measured so far: 700 builds / 31k events over 200 streams in 7.6 s on a dev server with debug SQL logging.
- Multi-node: libcluster (`CLUSTER_STRATEGY=dns|ec2|k8s`), PubSub PG2, `Phoenix.Tracker` or always-publish digests, S3 required when clustered, `/health/live` + `/health/ready`, graceful drain (`SHUTDOWN_DRAIN_SECONDS`), `deploy/kubernetes` manifests + `deploy/aws-asg` Terraform, 3-node load profile with scale-in and node kill.

### M8 — ops + release
Dockerfile (release, non-root), `docker-compose.yml` (app + Postgres), `Conveyor.Release.migrate` on boot, retention (`RETENTION_DAYS`, `RETENTION_RAW_DAYS`), Grafana dashboard JSON, docs (quickstart, bazelrc recipes incl. `--build_event_upload_max_retries=10`, OIDC guides, CI recipes, sizing), Bazel-in-CI e2e matrix (7/8/9), v0.1.0.

## 8. Open decisions for the user (ask when they matter)

1. ~~CAS sink~~ shipped behind `CAS_SINK_ENABLED` (default off).
2. Bazel version floor (suggest 7.x+).
   (M6 chose: open mode by default with ADMIN_TOKEN; OIDC generic, not provider-specific.)
3. Reference hardware for the load-test envelope.
4. Raw event retention default: 7 vs 14 days.
5. Two ports (1985 gRPC, 4000 web) vs one multiplexed port — recommended two.
(Decided: Oban; blob store both adapters; Kubernetes + EC2 ASG examples both.)

## 9. Testing conventions

- Unit tests are async; anything touching ingest workers/writers uses `Conveyor.IngestCase` (shared sandbox, gRPC on a random port, `await_worker_exit/1`) or `ConveyorWeb.LiveCase` (`ingest_fixture!/2` pushes a fixture through the real pipeline with `Ingest.push_sync/2`).
- Fixtures in `test/fixtures/bep/*.bep` (scenarios: clean_build_and_test, cached_build_and_test, build_failure, test_failure, flaky_test, analysis_failure, build_only_verbose) recorded from `test/fixtures/workspace` with `--build_event_binary_file` and `--build_event_publish_all_actions`; re-scrub with `Conveyor.Ingest.Scrub` if re-recorded.
- Query tests compare SQL and in-memory results for every operator; keep both evaluators in sync.
- LiveView tests assert on element ids (see AGENTS.md rules); stream containers need ids on every child including empty-state rows; hooks need unique ids.
- Expected error logs in failure-path tests carry `@tag :capture_log`.
