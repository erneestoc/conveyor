# Bazel Build Event Service (BES) server and build observability UI — implementation plan

Working name: **bes** (placeholder; see Open decisions). License: MIT.
Stack: Elixir 1.20 / OTP 29, Phoenix 1.8 + LiveView 1.1, PostgreSQL 16+, elixir-grpc 1.x.

---

## 1. Goals and non-goals

**Goals**

- Accept Bazel's Build Event Protocol (BEP) over the standard BES gRPC API so any Bazel client can report with only flags (`--bes_backend`, `--bes_header`, `--bes_results_url`).
- Persist every invocation and make it browsable: live list, per-build detail with log, timeline, targets, tests, actions, metrics, metadata, raw events.
- Schema-less tagging (`--build_metadata=KEY=VALUE`, `--bes_keywords`, workspace status, per-key defaults) with a free-form query language and facets.
- Dashboard: success/failure rate, duration percentiles (p50/p90/p99) per user-defined segment (Local vs CI, human vs AI, etc.), cache hit rate, execution strategy mix, slowest targets/tests, flaky tests, trends.
- Real-time everything via LiveView: list status, counters, log tail, timeline growth, metrics as they arrive.
- gRPC ingest authenticated by API key; web UI open or behind OIDC (Okta, Google, Entra, Keycloak, Dex).
- Multiple **projects** (apps/repos) per deployment, each with its own API keys, dashboards and settings; keys rotate without downtime.
- Scale on a single application node: hundreds of machines streaming concurrently, thousands of builds per hour, and **no acknowledged event is ever lost** (§13). Load-tested continuously (§15).
- Scale out to several application nodes in an auto-scaling group behind a gRPC-aware load balancer, with no cluster-level coordination required for correctness (§13.2).
- Single Docker image + Postgres; simple env-var configuration; runnable by any company.

**Non-goals (v1)**

- Remote execution / full remote cache. We optionally implement a *minimal* Content-Addressable Storage (CAS) sink for BEP artifacts (profile, test logs), not a general cache.
- Multi-tenant SaaS (orgs, billing). One deployment = one company with many projects; a later `organization_id` above projects is left room for.
- Reproducing BuildBuddy. Original implementation from Bazel protos and docs only.

---

## 2. Protocol primer (verified against current Bazel `master` and googleapis)

### 2.1 Service surface (`google.devtools.build.v1.PublishBuildEvent`)

| RPC | Mode | Purpose |
|---|---|---|
| `PublishLifecycleEvent(PublishLifecycleEventRequest) → Empty` | unary | `BuildEnqueued`, `InvocationAttemptStarted`, `InvocationAttemptFinished`, `BuildFinished`. Sent before/after the stream when `--bes_lifecycle_events=true` (default). |
| `PublishBuildToolEventStream(stream Request) → stream Response` | bidi | The BEP stream. Each request carries `OrderedBuildEvent{stream_id, sequence_number, event}`. Server must reply `Response{stream_id, sequence_number}` for **every** event, **in order**. |

- `StreamId{build_id, invocation_id, component=TOOL}`. `invocation_id` = Bazel's per-command UUID (also `BuildStarted.uuid`); `build_id` groups invocations (`--build_request_id`), otherwise random.
- `BuildEvent.event_time` + oneof: `bazel_event` (an `Any` wrapping `build_event_stream.BuildEvent`), `component_stream_finished` (last message), `console_output`, lifecycle variants.
- `project_id` ← `--bes_instance_name` (use as an optional namespace later). `notification_keywords` ← `--bes_keywords` (prefixed `user_keyword=`) and `--bes_system_keywords`.
- **Retry semantics:** if the server errors or the connection drops, Bazel reopens the stream and resends from the first un-acked sequence number. The server must be idempotent on `(invocation_id, sequence_number)` and must never ack out of order. Ack only after the event is durably persisted; with the default `--bes_upload_mode=wait_for_upload_complete` Bazel blocks at the end of the build until the last ack, so ack latency is user-visible.
- Auth is plain gRPC metadata: `--bes_header=x-api-key=<key>` (any header name; we accept `x-api-key` and `authorization: Bearer`).
- Plaintext `grpc://host:port` or TLS `grpcs://host:port`.

### 2.2 BEP events we consume (`build_event_stream.BuildEvent{id, children, last_message, payload}`)

| Payload | What we take from it |
|---|---|
| `Started` | `uuid`, `start_time`, `build_tool_version`, `command` (build/test/run/…), `options_description`, `working_directory`, `workspace_directory`, `host`, `user`, `server_pid` |
| `Progress` | `stdout` / `stderr` chunks → the **build log** (ANSI-coloured; Bazel's UI writes to stderr). Chunk size bounded by `--bes_outerr_chunk_size`. |
| `UnstructuredCommandLine`, `StructuredCommandLine`, `OptionsParsed` | full command line, explicit vs. rc-file options, `--config` names |
| `WorkspaceStatus` | key/values from `--workspace_status_command` (`BUILD_USER`, `BUILD_HOST`, `BUILD_EMBED_LABEL`, custom `STABLE_*`/git info) → tags |
| `BuildMetadata` | `metadata` map from `--build_metadata=K=V` → **primary tag source** |
| `PatternExpanded`, `TargetConfigured`, `Configuration` | target patterns, target kinds, configurations (mnemonic, platform, cpu) |
| `NamedSetOfFiles` | file-set DAG referenced by `TargetComplete.output_group` and test outputs. May arrive **after** its referrers → resolve lazily. |
| `TargetComplete` | per-target success/failure, `failure_detail`, output groups |
| `ActionExecuted` | failed actions by default; **all** actions with `--build_event_publish_all_actions`. Has `type` (mnemonic), `exit_code`, `stdout`/`stderr`/`primary_output` files, `start_time`, `end_time`, `command_line`. |
| `TestResult` | per `(label, run, shard, attempt)`: `status`, `cached_locally`, `execution_info.cached_remotely`, `strategy`, `test_attempt_start`, `test_attempt_duration`, `test_action_output` (`test.log`, `test.xml`) |
| `TestSummary`, `TargetSummary` | overall test status (PASSED/FAILED/FLAKY/TIMEOUT/…), run counts, `total_run_duration` |
| `Aborted` | reasons: USER_INTERRUPTED, NO_BUILD, TIME_OUT, LOADING_FAILURE, ANALYSIS_FAILURE, OUT_OF_MEMORY, … |
| `BuildFinished` | `exit_code{name, code}`, `finish_time`, `failure_detail` |
| `BuildToolLogs` | `File`s: `elapsed time`, `critical path`, `process stats`, **`command.profile.gz`** (JSON trace profile) — referenced by `bytestream://` URI when uploaded to a remote cache, `file://` otherwise |
| `BuildMetrics` | `ActionSummary` (actions created/executed, per-mnemonic `ActionData`, `RunnerCount{name, count, exec_kind}` = local / worker / sandbox / remote / **remote cache hit**, `ActionCacheStatistics` hits/misses), `MemoryMetrics`, `TargetMetrics`, `PackageMetrics`, `TimingMetrics` (cpu, wall, analysis phase, execution phase, `critical_path_time`), `CumulativeMetrics`, `ArtifactMetrics`, `BuildGraphMetrics`, `WorkerMetrics`, `WorkerPoolMetrics`, `NetworkMetrics` |

### 2.3 Artifacts referenced by BEP (profile, test logs, action stdout/stderr)

Bazel does not push file contents through BES. It uploads BEP-referenced files to the configured `--remote_cache` and emits `bytestream://host/blobs/<sha256>/<size>` URIs (`--remote_build_event_upload=minimal` still uploads the "important" files: the profile and test outputs — verify exact set in M0). Without a remote cache the URIs are `file://` paths on the developer's machine and unreachable. We therefore support three retrieval paths (§9).

### 2.4 Client flags we will document

```
# .bazelrc
build --bes_backend=grpcs://bes.example.com:443
build --bes_results_url=https://bes.example.com/invocation/
build --bes_header=x-api-key=bes_xxx            # or via --bes_header in a CI-only rc / env wrapper
build --build_metadata=USER=alice --build_metadata=CI=false --build_metadata=AI=true
build --bes_upload_mode=wait_for_upload_complete   # default; fully_async for CI speed
build --bes_timeout=60s
build --build_event_upload_max_retries=10          # default 4: Bazel gives up on a BES outage within a few seconds
build --remote_cache=grpcs://cache.example.com     # profile/test logs become fetchable
build --remote_build_event_upload=minimal
build --experimental_profile_include_target_label
build --experimental_profile_include_primary_output
# optional richness
build --build_event_publish_all_actions            # per-action timeline without profile
```

Note: `.bazelrc` cannot expand environment variables, so per-user tags come from a `--workspace_status_command`, a `tools/bazel` wrapper, or a CI-injected `--build_metadata`. We'll ship example wrappers.

---

## 3. Architecture

```
 bazel ──grpc(s)──▶ BES gRPC server (elixir-grpc on Cowboy, :1985)
                         │  auth interceptor (API key) → per-invocation IngestWorker
                         ▼
             ┌── Ingest pipeline ──────────────────────────────┐
             │ decode Any → BEP → Normalizer (state machine)   │
             │ per-invocation worker → sharded group-commit    │
             │ writers → Postgres (event/log segments, targets, │
             │ tests, actions, metrics, tags)                   │
             │ ack(seq) only after commit                       │
             │ PubSub broadcast (coalesced) ───────────────┐    │
             └─────────────────────────────────────────────┼────┘
                                                           ▼
 browser ◀──websocket──▶ Phoenix LiveView (:4000) ◀── Phoenix.PubSub
                         │  auth plug (open | OIDC)
                         ▼
             Postgres (JSONB tags + GIN, aggregates)   Blob store (disk | S3): profiles,
                                                       fetched artifacts, compacted logs
 optional: ByteStream/CAS sink (same gRPC listener) ◀── bazel --remote_cache
           artifact fetcher (gRPC ByteStream client) ──▶ customer's remote cache
```

**Processes (OTP):**

- `Bes.Grpc.Endpoint` — elixir-grpc endpoint; services `PublishBuildEvent`, optional `ByteStream`, `ContentAddressableStorage`, `Capabilities`; interceptors: auth, logging, telemetry.
- `Bes.Ingest.WorkerSupervisor` (DynamicSupervisor) + `Registry` keyed by `invocation_id`. One `IngestWorker` GenServer per live invocation: owns ordering, dedup, normalization, state machine, broadcasts, finalization, and the idle timeout. The gRPC handler process is a thin forwarder: `call(worker, {:event, seq, event})` returns once `seq` is committed, then the handler sends the ack.
- `Bes.Ingest.Writer` pool: N group-commit writers (N ≈ schedulers) sharded by invocation id. Workers hand them normalized batches; each writer commits one multi-invocation transaction every 20–50 ms (`COPY`/`insert_all`), then replies to every waiting worker. This is what keeps thousands of concurrent streams from turning into thousands of tiny transactions (§13).
- `Bes.Artifacts.Fetcher` (Task supervisor + cache) and job runner (`Oban` or a minimal in-house queue) for profile parsing, artifact fetch, retention, rollups.
- `BesWeb.Endpoint` — Phoenix; LiveViews subscribe to `Phoenix.PubSub` topics.

**Nodes:** one node is the default; several identical nodes behind a load balancer form a cluster (libcluster + distributed Erlang for PubSub, Postgres for everything durable). See §13.2.

**Ports:** gRPC on `1985` (Cowboy/ranch HTTP/2, TLS via `GRPC.Credential`), web on `4000`. Both behind the operator's proxy/ingress in production; document single-host setups (Caddy/nginx with h2 passthrough for gRPC).

---

## 4. Tech stack and dependencies (all MIT-compatible)

| Concern | Choice | License |
|---|---|---|
| Web/live UI | phoenix, phoenix_live_view, bandit, tailwind (Phoenix default), heroicons | MIT |
| DB | ecto_sql, postgrex | Apache-2.0 |
| gRPC server/client | `grpc_server` + `grpc` (elixir-grpc 1.0.x, Cowboy adapter) | Apache-2.0 |
| Protobuf | `protobuf` (protobuf-elixir) + `protoc` plugin at dev time; generated modules checked in | MIT |
| OIDC | `assent` (`Assent.Strategy.OIDC`, discovery + PKCE) | MIT |
| Jobs | `oban` (OSS): Postgres-backed queues with unique jobs, so cron/retention/parsing run exactly once across nodes | Apache-2.0 |
| Clustering | `libcluster` (DNS, EC2 tag, Kubernetes strategies) + `Phoenix.PubSub` PG2 adapter + `Phoenix.Tracker` | MIT |
| HTTP client | `req` (S3, OIDC endpoints) | Apache-2.0 |
| S3 (optional) | `ex_aws`, `ex_aws_s3` or `req_s3` | MIT |
| Charts | small custom SVG/Canvas components rendered by LiveView + a canvas JS hook for the timeline; no chart library required | — |
| Vendored protos | Bazel `build_event_stream.proto` + imports, googleapis `google/devtools/build/v1/*`, `google/bytestream`, `bazelbuild/remote-apis` `remote_execution.proto` | Apache-2.0 (keep LICENSE/NOTICE in `priv/protos/`) |

Proto set to vendor and compile (with `google/api/*.proto` + `google/rpc/status.proto` transitive deps):

```
google/devtools/build/v1/{build_events,build_status,publish_build_event}.proto
bazel: src/main/java/com/google/devtools/build/lib/buildeventstream/proto/build_event_stream.proto
       src/main/protobuf/{command_line,option_filters,failure_details,invocation_policy,action_cache}.proto
       src/main/java/com/google/devtools/build/lib/packages/metrics/package_load_metrics.proto
       src/main/java/com/google/devtools/build/lib/skyframe/serialization/analysis/proto/analysis_cache_service_metadata_status.proto
google/bytestream/bytestream.proto, build/bazel/remote/execution/v2/remote_execution.proto, build/bazel/semver/semver.proto
```

Pin the Bazel proto snapshot to a Bazel release tag (9.x) and record it in `priv/protos/VERSION`; newer Bazel adds fields but stays wire-compatible. Unknown fields are preserved by the decoder, so old servers tolerate new clients.

---

## 5. Data model (PostgreSQL)

All timestamps `timestamptz`, ids of invocations are the Bazel UUID (`uuid` PK).

```
projects                          -- an "app": a repo/workspace/team; every invocation belongs to one
  id bigserial PK, slug text UNIQUE, name text, settings jsonb (segments, retention override,
  allowed_groups for OIDC, artifact cache endpoints), archived_at, inserted_at

invocations
  id uuid PK                       -- Bazel invocation_id
  project_id bigint FK NOT NULL, build_id text, bes_instance_name text, api_key_id bigint FK null
  status text  -- in_progress | succeeded | failed | aborted | disconnected | unknown
  exit_code_name text, exit_code int, abort_reason text
  command text, patterns text[], options_description text
  bazel_version text, host text, "user" text, cwd text, workspace text
  started_at, finished_at, duration_ms bigint (nullable while running; UI ticks)
  last_event_seq bigint, last_event_at, stream_finished bool, lifecycle_finished bool
  tags jsonb NOT NULL DEFAULT '{}'                -- merged K→V (see §7)
  -- denormalized counters for list/dashboard (updated by worker, final on finish)
  targets_configured int, targets_completed int, targets_failed int
  tests_total int, tests_passed int, tests_failed int, tests_flaky int, tests_timed_out int
  actions_created bigint, actions_executed bigint
  remote_cache_hits bigint, remote_exec int, local_exec int, worker_exec int, sandbox_exec int
  action_cache_hits bigint, action_cache_misses bigint
  analysis_ms bigint, execution_ms bigint, critical_path_ms bigint, cpu_ms bigint
  peak_heap_bytes bigint, packages_loaded int, bytes_sent bigint, bytes_recv bigint
  profile_status text  -- none | referenced | fetching | ready | failed
  profile_uri text, profile_blob text
  search tsvector generated (patterns, command, user, tags text)
  inserted_at, updated_at
  INDEX (project_id, started_at DESC), (project_id, status, started_at DESC),
        GIN (tags jsonb_path_ops), GIN(search)

event_segments      -- raw BEP, stored as batches not rows (§13); range-partitioned by day
  invocation_id uuid, first_seq bigint, last_seq bigint, count int, event_time_min/max
  kinds text[] (payload names present), payload bytea  -- zstd(varint-delimited BuildEvent protos)
  PK (invocation_id, first_seq)

log_segments        -- Progress stdout/stderr, same batching; range-partitioned by day
  invocation_id uuid, first_seq bigint, last_seq bigint, byte_offset bigint, line_offset int
  data bytea  -- zstd(raw ANSI text)      PK (invocation_id, first_seq)
  -- byte_offset/line_offset let the log view seek without decompressing everything

targets
  invocation_id, label, aspect text, configuration_id text (attribute, not part of the key: TargetConfigured carries no configuration, so a target is one row per label+aspect and the last configuration wins)
  kind text, status text (configured|success|failed), test_status text, test_size text
  first_seen_at, completed_at, failure_message text, output_groups jsonb
  UNIQUE (invocation_id, label, aspect)

test_results
  invocation_id, label, run int, shard int, attempt int
  status text, cached_locally bool, cached_remotely bool, strategy text, hostname text
  started_at, duration_ms, exit_code int, log_uri text, xml_uri text, files jsonb
  PK (invocation_id, label, run, shard, attempt)

actions   -- ActionExecuted
  id bigserial, invocation_id, label, mnemonic, configuration_id, success bool, exit_code int
  started_at, ended_at, duration_ms, primary_output text, stdout_uri, stderr_uri, command_line text[]
  INDEX (invocation_id, started_at)

invocation_metrics  -- 1:1, full BuildMetrics + BuildToolLogs as jsonb for the Metrics tab
  invocation_id PK, build_metrics jsonb, action_data jsonb, runner_counts jsonb, worker_metrics jsonb, tool_logs jsonb

named_sets  -- NamedSetOfFiles, resolved lazily
  invocation_id, set_id text, files jsonb, child_set_ids text[]   PK(invocation_id, set_id)

tag_keys    -- facets / autocomplete
  key text, value text, count bigint, last_seen_at   PK(key, value)

api_keys     -- scoped to exactly one project; several active per project (rotation)
  id, project_id FK, key_id text UNIQUE (8 chars, public part), key_hash bytea (sha256 of secret),
  name, scopes text[] ('ingest','read','upload'), default_tags jsonb,
  expires_at, revoked_at, last_used_at, last_used_ip inet, rotated_from_id FK null,
  created_by_user_id, inserted_at

users        -- only populated in OIDC mode
  id, subject, issuer, email, name, role ('admin'|'viewer'), last_login_at
project_members  -- optional per-project restriction (empty = all viewers may see the project)
  project_id, user_id, role

audit_log    -- admin/security events: key created/rotated/revoked, project changes, logins, settings
  id, at, actor_user_id, actor_key_id, action, subject_type, subject_id, details jsonb, ip

settings     -- global singleton: auth, retention defaults, dashboard defaults, limits

blobs        -- registry for blob store objects (profiles, artifacts, compacted logs)
  key text PK, sha256, size, content_type, storage ('disk'|'s3'), inserted_at
```

Retention: `event_segments`/`log_segments` are daily partitions, so pruning after `RETENTION_RAW_DAYS` (default 14) is a `DROP PARTITION` (no vacuum storm). Whole invocations go after `RETENTION_DAYS` (default 90), overridable per project. Optional cold tiering (later milestone) moves finished segments into one object per invocation in the blob store.

---

## 6. Ingestion design

1. **Auth interceptor**: read `x-api-key` / `authorization` from gRPC metadata; parse `bes_<key_id>_<secret>`; look up `key_id` (ETS cache, 30 s TTL, invalidated on revoke); constant-time compare `sha256(secret)`; check `expires_at`/`revoked_at`/scope `ingest`; return `UNAUTHENTICATED`/`PERMISSION_DENIED` otherwise. Attach `{project, api_key}` to the stream context — the **project is always decided by the key**, never by client-supplied `project_id`/metadata (`--bes_instance_name` is recorded for display only). `BES_INGEST_AUTH=none` allowed for dev (single default project).
2. **Stream handler** (`publish_build_tool_event_stream(req_stream, stream)`): for each request, `IngestWorker.push(invocation_id, ordered_event)`; the worker replies when that seq is committed; the handler then `GRPC.Server.send_reply(stream, ack)`. On `component_stream_finished` reply and finish the stream. Any crash → gRPC error → Bazel retries from last ack.
3. **IngestWorker** state: `invocation_id`, `expected_seq`, `pending` batch, `named_sets` map, `last_event_at`, counters, `subscribers`.
   - Dedup: `seq < expected_seq` → ack immediately (already committed). `seq > expected_seq` → protocol violation → `FAILED_PRECONDITION` (Bazel will restart from last ack).
   - Batching: accumulate up to 500 events / 256 KB / 50 ms, then hand the normalized batch (one `event_segments` row, zero or one `log_segments` row, upserts for targets/tests/actions, counter deltas) to the writer shard for this invocation. The writer commits a group of batches from many invocations in one transaction and replies; the worker then releases the acks. Typical ack latency 20–80 ms; bounded by the writer flush interval under load.
   - Decoding: `bazel_event` `Any` → `BuildEventStream.BuildEvent`; dispatch on payload oneof to `Bes.Ingest.Normalizer.handle/3` (pure functions, easily unit-tested).
   - Broadcasts: coalesce into a digest every 250 ms per invocation: `{:invocation_updated, summary}` on `"invocations"`, `{:log, chunks}` on `"inv:<id>:log"`, `{:targets, diff}`, `{:tests, diff}`, `{:actions, diff}`, `{:metrics, ..}` on `"inv:<id>"`.
   - Finalization: on `BuildFinished` payload → status from exit code (`SUCCESS`→succeeded; `BUILD_FAILURE`, `TESTS_FAILED`, `INTERRUPTED`, `OOM_ERROR`… → failed with `exit_code_name`; `Aborted` without finish → aborted). On `component_stream_finished` + lifecycle `BuildFinished` (or after grace period) → mark `stream_finished`, enqueue post-processing (profile fetch/parse, test XML fetch, tag_keys upsert), then stop after `BES_WORKER_LINGER` (30 s) to absorb late retries.
   - Idle timeout: no events for `BES_STREAM_IDLE_TIMEOUT` (default 10 min, or the `stream_timeout` hint from the lifecycle request) → status `disconnected`, worker exits. If Bazel reconnects later, a fresh worker rehydrates `expected_seq` and counters from the DB.
4. **Lifecycle RPC**: upsert invocation shell on `InvocationAttemptStarted` (so it appears in the list before the first BEP event), record `InvocationAttemptFinished.invocation_status` and `BuildFinished.status`.
5. **Backpressure**: per-worker mailbox is bounded by the fact that the handler waits on `call/3` per batch; gRPC flow control does the rest. Cap max inbound message size at 64 MB (large `NamedSetOfFiles`, progress chunks).
6. **Rehydration and fencing**: workers are ephemeral; state lives in Postgres. A new worker (after a restart, or on another node after a reconnect) reads `last_event_seq` from the invocation row and continues from there. Every batch commit updates that row with a compare-and-set (`WHERE last_event_seq = $expected_previous`) and `event_segments` has a primary key on `(invocation_id, first_seq)`, so a stale worker that still thinks it owns the invocation fails its commit and exits. No cluster lock is needed. On boot, `in_progress` invocations are marked `disconnected` only after the idle timeout, because clients reconnect and resume.
7. **Telemetry**: `:telemetry` events for events/sec, batch latency, ack latency, decode errors; exposed via `/metrics` (Prometheus text) — optional `prom_ex` or hand-rolled.

---

## 7. Tags and the query language

**Tag sources, merged in this precedence (later wins):**

1. Server-derived: `command`, `bazel_version`, `host`, `user` (from `Started.user`, fallback `BUILD_USER`), `platform`/`cpu` (Configuration), `status`, `exit_code`.
2. `WorkspaceStatus` items (all keys, e.g. `BUILD_USER`, `STABLE_GIT_BRANCH`).
3. `notification_keywords` → `keyword=<v>` entries and `user_keyword=` unpacked as `K=V` when they contain `=`.
4. API key `default_tags` (e.g. key "github-actions" adds `ci=true`).
5. `BuildMetadata.metadata` (`--build_metadata`) — authoritative.

All stored as string→string in `invocations.tags` (keys normalized to lowercase; original case kept for display in `tag_keys`). Reserved keys are prefixed `bes.` when a user key collides.

**Query syntax** (one line, used by the list, dashboard, and saved segments):

```
user:alice ci:true -status:succeeded command:test duration>5m started>-7d branch:main "//app/..."
key:value          equality (case-insensitive)     key:(a,b,c)  any-of
key!=value         not equal                        -term        negate
key>v key<v key>=v key<=v   numeric/duration/date compare (5m, 2h30m, 2026-09-01, -24h)
key~regex          Postgres regex (~*)              key:*        key present
"free text"        ILIKE over patterns, command line, labels of failed targets
```

Built-in keys resolve to columns (`status`, `command`, `user`, `host`, `pattern`, `duration`, `started`, `finished`, `exit`, `bazel`, `key` (API key name), `id`, `build`, `cache_hit_rate`, `targets_failed`, `tests_failed`, …); anything else resolves to `tags->>'key'`. Parser: hand-written recursive descent in `Bes.Query.Parser` (no dependency), compiler `Bes.Query.Ecto` → `Ecto.Query.dynamic`. Facets sidebar reads `tag_keys` (top 20 values per key) and offers click-to-add. Autocomplete in the search box uses the same table.

**Segments**: admin-defined named queries (defaults: `Local = ci!=true`, `CI = ci:true`). Dashboards render one series per selected segment.

---

## 8. Web UI (Phoenix LiveView)

Layout: top bar (project switcher, search box with query language + facet chips, time range, segment picker), left nav (Builds, Dashboard, Tests, Settings), content. Every view is scoped to the selected project; an "All projects" scope exists for the list and dashboard (admins, or any viewer when no project restrictions are configured). URLs carry the project slug (`/p/:slug/...`). Tailwind with a small custom token set; dark/light.

### 8.1 Builds list (`/`)
- LiveView `stream` of invocations, newest first, cursor-paginated (started_at, id). Subscribes to `"invocations"`; new invocations are inserted at top (respecting the current filter — the filter is re-evaluated on the summary in memory, falling back to a DB check when it references columns not in the summary).
- Row: status pill (spinner while in progress), command + patterns, user/host, tags (up to N chips, overflow "+3"), targets ✓/✗, tests ✓/✗/flaky, cache hit %, duration (ticks live), started (relative), bazel version. Row click → detail. Bulk facets on the right.
- URL carries `q=` and `range=` so filters are shareable.

### 8.2 Invocation detail (`/invocation/:id`) — the `--bes_results_url` target
Header: status, exit code name, command line (copyable), user@host, workspace, duration (live), bazel version, tags (all), API key, links (rerun command snippet). Tabs:

1. **Overview** — summary cards (targets, tests, actions executed, cache hit rate, remote/local mix, critical path, analysis/execution time), failure summary (failed targets with `failure_detail` messages, failed tests), phases strip (loading → analysis → execution), top slowest tests/actions.
2. **Log** — terminal-style view of `Progress` stderr+stdout, ANSI → styled spans (colors, bold; strip cursor-movement sequences from Bazel's curses UI), virtualized list via a JS hook (`push_event` appends chunks; no giant assigns), follow-tail toggle, search, download raw, line anchors (`#L120`).
3. **Timeline** — see §10.
4. **Targets** — table with status, kind, configuration, duration (from profile/actions when available), filter/sort, failure message expand; live updates as `TargetComplete` arrives.
5. **Tests** — grouped by label: overall status, runs/shards/attempts, cached locally/remotely, strategy, duration; click → `test.log` (fetched artifact) and parsed `test.xml` cases (JUnit) with per-case status/duration.
6. **Actions** — `ActionExecuted` rows (failed by default; all with the flag): mnemonic, label, exit code, duration, stdout/stderr (fetched), command line.
7. **Metrics** — all `BuildMetrics` groups as tables/mini-charts: per-mnemonic action counts and cpu/user time, runner counts (bar), action cache stats, memory (heap peaks, GC by type), package/target metrics, worker metrics, network, artifact metrics, build graph metrics; `BuildToolLogs` (critical path text, elapsed time, process stats).
8. **Details** — options parsed (explicit vs rc), structured command line, workspace status, configurations, `--config` names, environment-ish info; raw tags.
9. **Raw events** — paginated list of BEP events with kind + decoded JSON (collapsible), download `.bep.bin`/`.json`; replayable.

### 8.3 Dashboard (`/dashboard`)
Filter bar (query + range + segments) drives every panel. Panels (§11). Real-time: subscribe to `"invocations"`, re-query changed panels at most every 5 s.

### 8.4 Tests (`/tests`)
Cross-invocation view: flaky tests (FLAKY summaries / attempts>1 in window), slowest tests (p50/p90 duration per label), most-failing tests, per-test history sparkline; click → recent invocations.

### 8.5 Settings (admin)
Projects (create/archive, slug, per-project segments, retention, allowed groups), API keys per project (create → show once, name, scopes, default tags, expiry, **rotate**, revoke, last used at/from), audit log, global auth info, artifact fetch config (cache endpoints + headers, per project or global), limits, server health and live ingest telemetry (streams, events/s, writer queue depth, ack latency).

### 8.6 Real-time plumbing
`Phoenix.PubSub` topics: `invocations`, `inv:<id>`, `inv:<id>:log`. Digests every 250 ms from the worker keep websocket traffic bounded even for builds emitting thousands of events per second. LiveView `stream`s for lists; `push_event` + hooks for log and timeline; `temporary_assigns` where appropriate.

---

## 9. Artifacts (profile, test logs, action outputs)

Uniform `Bes.Artifacts.fetch(invocation, file)` with caching into the blob store (`blobs` table + disk/S3) keyed by digest:

1. **`bytestream://` URIs** (from any remote cache): gRPC `ByteStream.Read` client to the URI host; credentials from Settings "cache endpoints" (host → headers such as `x-api-key`, or mTLS) — mirrors what the user passes with `--remote_header`. Fetch lazily on first view and eagerly for the profile at finalization.
2. **Built-in CAS sink** (optional service on the same gRPC port): `ByteStream.Write/Read/QueryWriteStatus`, `ContentAddressableStorage.FindMissingBlobs/BatchUpdateBlobs/BatchReadBlobs`, `Capabilities.GetCapabilities` (advertise `cache_capabilities` only, sha256, no exec). Lets users without a remote cache set `--remote_cache=grpcs://bes-host --remote_upload_local_results=false --remote_build_event_upload=minimal` (verify in M0 that `noremote_accept_cached`/`remote_upload_local_results=false` keeps action result traffic away while still uploading BEP files). Blobs land directly in the blob store, TTL-pruned.
3. **HTTP upload API**: `PUT /api/v1/invocations/:id/artifacts/:name` (`x-api-key`), used by a shipped `bes-upload-profile` script / `tools/bazel` wrapper for environments with no cache (`--profile=/tmp/p.gz` then upload). Also `PUT /api/v1/invocations/:id/bep` to accept a `--build_event_binary_file` after the fact (useful for air-gapped CI).
4. `file://` URIs are shown as unavailable with a hint pointing to options 1–3.

Blob store abstraction `Bes.Blob` with `Disk` (default for single node, `BLOB_DIR`) and `S3` adapters; S3 is required in multi-node mode (§13.2).

---

## 10. Timeline

Two data tiers rendered by one canvas component (JS hook, no library):

**Tier A — from BEP (always available, streams live):**
- Phase bar: `started_at` → first `TargetConfigured`/`PatternExpanded` (loading) → `TimingMetrics.actions_execution_start_in_ms` / first `TargetComplete` (analysis) → `finish_time` (execution). Filled in live with best-known boundaries.
- Lanes: tests (`TestResult` start+duration per shard/run/attempt, colored by status/cached), actions (`ActionExecuted` start/end; all actions with `--build_event_publish_all_actions`), target completion ticks.
- Good enough for "what ran when, what was slow, what failed" without any cache.

**Tier B — from `command.profile.gz` (JSON trace-event format):**
- Rows per `pid/tid` (`main`, `skyframe-evaluator-N`, `critical path`, `remote-executor`, workers…), `X` events with `name`, `cat` (`action processing`, `remote action execution`, `local action execution`, `critical path component`, `skyframe evaluator`, …), `args.target`/`mnemonic`/`out` (flags in §2.4). Counter (`C`) events (CPU, memory, actions in flight, network) drawn as small area charts above the lanes.
- Rendering: server serves the gz via an HTTP endpoint; a Web Worker decompresses (`DecompressionStream`) and parses; the canvas hook draws lanes with zoom/pan (wheel/drag), hover tooltip, click → event details drawer, search/highlight by name/target/mnemonic, filter by category, "critical path only" toggle. Large profiles: bin events below 1 px at the current zoom (Bazel's `--slim_profile` already merges tiny events).
- Server-side summary job (Elixir, streaming JSON decode): per-category and per-mnemonic total time, critical path components list, phase durations, top 50 longest events → stored in `invocation_metrics.profile_summary` and shown in Overview/Metrics, and aggregated in the dashboard ("where does build time go").

Tier B replaces Tier A lanes when available; Tier A remains the live view while a build runs.

---

## 11. Dashboard metrics catalogue

All panels honor the global filter + time range and split by selected segments (Local/CI/AI/…):

- Builds over time (stacked succeeded/failed/aborted), success rate %, failure breakdown by `exit_code_name` (BUILD_FAILURE vs TESTS_FAILED vs INTERRUPTED vs OOM…) and top failing targets/tests.
- Duration p50 / p90 / p99 (whole build, analysis phase, execution phase, critical path) as daily/hourly series and as current-window big numbers; histogram of durations.
- Cache: remote cache hit rate (`RunnerCount` "remote cache hit" ÷ actions executed), action cache hit rate (`ActionCacheStatistics`), trend over time; builds with zero cache hits (misconfig detector).
- Execution strategy mix (remote / local / worker / sandbox / cache hit) over time; per-mnemonic time (from `ActionData.system_time+user_time` and profile summaries).
- Throughput: builds per user, per host, per API key; unique users/day; most-built patterns/commands.
- Tests: pass/fail/flaky rates, flakiest tests, slowest tests, timeouts, cached test share.
- Resources: peak heap, packages loaded, targets configured, actions created vs executed (incrementality), network bytes.
- Versions: Bazel version distribution, `--config` usage.
- Leaderboards: slowest builds, longest critical paths, biggest analysis phases.

Queries run over `invocations` denormalized columns with `percentile_cont` grouped by `date_trunc`; GIN on tags keeps filtering cheap. If needed later: `invocation_rollups_hourly` maintained by a job (keyed by segment id) — not in v1.

---

## 12. Authentication, projects, keys, and security

### 12.1 Projects (multiple apps)
- A deployment hosts many **projects** (an app, repo, or team). Every invocation, key, segment, dashboard and retention rule belongs to a project. The list and dashboard can also be viewed across all projects.
- The project of an invocation is derived from the API key that authenticated the stream. Clients cannot choose or spoof it. `--bes_instance_name` is stored only as informational metadata.
- Project settings: segments, retention override, artifact cache endpoints/credentials, optional OIDC group restriction (`allowed_groups`).

### 12.2 API keys (gRPC ingest, upload API, read API)
- Format `conveyor_<key_id>_<secret>`: `key_id` is 8 base32 chars (public, indexed, shown in the UI), `secret` is 32 random bytes base64url. Only `sha256(secret)` is stored; lookup by `key_id`, then constant-time compare. Shown exactly once at creation.
- Scoped to one project; several active keys per project (per CI system, per team, per environment). Scopes: `ingest`, `upload` (profile/BEP upload API), `read` (JSON API). Optional `expires_at`. `default_tags` (e.g. `ci=true`) applied to every build.
- Accepted as `x-api-key: <key>` or `authorization: Bearer <key>` in gRPC metadata / HTTP headers.
- **Rotation without downtime**: *Rotate* creates a successor key (same name, scopes, tags; `rotated_from_id` set) and gives the old key a grace expiry (default 7 days, configurable). Operators roll the new key out to CI secrets / developer wrappers while both work. The UI shows `last_used_at` and `last_used_ip` per key, so you can see when the old key is dead and revoke it early. Expiring keys are surfaced on the Settings page and via a `/api/v1/keys/expiring` endpoint (for alerting). Revocation is immediate (ETS cache invalidated through PubSub); in-flight streams keep running to their end unless "revoke and disconnect" is chosen.
- Scoping for humans: a personal-key flow is deliberately out of scope for v1 (keys are project credentials, distributed by admins); developers identify themselves through tags (`--build_metadata=USER=…`) which are not security-relevant.
- Auditing: every create/rotate/revoke, login, project and settings change lands in `audit_log`.

### 12.3 Web authentication
- `AUTH_MODE=open | oidc`.
- `oidc`: generic OpenID Connect via discovery (`OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_SCOPES`), authorization-code + PKCE + `state`/`nonce`, session cookie (`Secure`, `HttpOnly`, `SameSite=Lax`, rotating id, idle and absolute expiry), logout to end-session endpoint when advertised. Works with Okta, Google, Entra ID, Keycloak, Dex, Authentik.
- Roles: `viewer` (read-only) and `admin` (projects, keys, settings). Admin assignment via `ADMIN_EMAILS` and/or `OIDC_ADMIN_GROUPS` matched against `OIDC_GROUPS_CLAIM` (default `groups`). `ALLOWED_EMAIL_DOMAINS` optional. Projects may restrict viewing to OIDC groups (`allowed_groups`).
- `open`: no login; everyone is admin unless `ADMIN_TOKEN` is set (then settings/keys require it). Intended for localhost/trusted networks; the UI shows a persistent banner in this mode.
- `/health` and `/metrics` bypass auth (optionally token-protected).

### 12.4 Security checklist (built in, tested in M6)
- **Secrets never persisted**: server-side scrubbing of `--bes_header`, `--remote_header`, `--remote_exec_header`, `--remote_cache_header`, `--remote_downloader_header` values, URL credentials, and anything matching common token patterns (`token=`, `secret=`, `api_key=`, `Bearer …`) in `BuildStarted.options_description`, `OptionsParsed`, `UnstructuredCommandLine`, `StructuredCommandLine`, `ActionExecuted.command_line` and the Progress log before the bytes hit disk; the raw protobuf is rewritten, not just the view. This matters more than expected: Bazel copies the *client environment* into the command line as `--client_env=NAME=VALUE`, so any token in a developer's shell environment would otherwise be stored. (Found in M1: the recorded fixtures contained one, now scrubbed.)
- **Transport**: TLS on the gRPC port (`grpcs://`) or terminate at the proxy; HSTS on the web port; document mTLS at the proxy for high-security sites.
- **Abuse limits per key** (settings, sane defaults): max concurrent streams, max events/s, max event size (64 MB), max per-invocation raw bytes (e.g. 2 GB, beyond which log bytes are truncated with a marker while structured events keep flowing), max invocations/hour; upload API size caps; gzip-bomb guard when parsing profiles (streaming decompression with an output cap).
- **SSRF**: artifact fetch only to configured cache endpoints (host allow-list), no redirects, private-range guard when `CACHE_ENDPOINTS` isn't set.
- **Web**: Phoenix CSRF, strict CSP (no inline scripts except the LiveView bootstrap nonce), `X-Frame-Options: DENY`, HTML-escaped ANSI/log rendering, download endpoints with `Content-Disposition: attachment` and `nosniff`, artifact/blob access always authorized through the invocation's project, blob keys are digests (no path traversal), no secrets in logs (redaction in the Logger formatter), `ADMIN_TOKEN` compared in constant time.
- **Supply chain / ops**: `mix hex.audit`, `mix deps.audit` and `sobelow` in CI, pinned deps, non-root distroless-ish image, DB role with least privilege, migrations run by a separate role if desired, `SECRET_KEY_BASE` and OIDC secret only via env/secret files, documented backup/restore.
- **Threat model doc** in `docs/security.md`: assets (build logs, command lines, source paths, user identities), trust boundaries (Bazel clients hold ingest keys; the web holds identities), mitigations above, and what we deliberately do not protect against (a malicious key holder can flood their own project until rate-limited).

---

## 13. Performance, durability, and scale

### 13.1 Single node

**Target envelope (v1, one application node + one Postgres):**

| Dimension | Target |
|---|---|
| Concurrent open BES streams | 1,000 (hundreds of machines each running builds, plus CI fan-out) |
| Sustained ingest | 30k BEP events/s, 50 MB/s of log text, with bursts 3× |
| Builds | 5,000/hour, 1M+ retained invocations |
| Ack latency | p50 < 50 ms, p99 < 250 ms under the sustained target |
| Loss | zero acknowledged events lost across server restarts, DB failovers, client reconnects |
| Hardware | 8 vCPU / 16 GB app node; Postgres 8 vCPU / 32 GB / NVMe |

**Why events are safe.** An event is acknowledged only after the transaction containing it has committed with `synchronous_commit=on`. Bazel retries from the last un-acked sequence on any failure, so a crash between receipt and commit costs nothing: the client resends. Duplicates are dropped by sequence number. Result: at-least-once delivery from Bazel + idempotent, ordered commit on our side = exactly-once persistence. The trade-off is explicit and documented: we never buffer unacked data anywhere but memory, so the durable throughput is Postgres's.

**Design choices that make the numbers reachable:**

1. **Segments, not rows.** Raw BEP and log text are stored as compressed batches (`event_segments`/`log_segments`, zstd, ≈300–1000 events per row). 30k events/s becomes ≈50–100 rows/s of raw data. Structured rows (targets, tests, actions, metrics) are a small fraction of events. Zstd on protobuf/log text typically yields 5–10× reduction.
2. **Group commit.** N writer shards (≈ scheduler count) each commit one transaction every 20–50 ms containing batches from many invocations, via `COPY ... FROM STDIN` (Postgrex streams) for segments and multi-row `INSERT ... ON CONFLICT` for structured tables. One fsync per writer flush instead of one per invocation batch. Writers are the only DB-writing processes on the hot path; the pool is sized for them plus read traffic.
3. **Backpressure instead of buffering.** Worker → writer handoff is a bounded `call`. If the writer is behind, workers block, the gRPC handler stops reading, HTTP/2 flow control fills, and Bazel slows its upload (it keeps its own buffer and, with `wait_for_upload_complete`, waits at the end of the build). Nothing is dropped; the system degrades to "slower acks", never to "lost data". Queue depth and blocked-time are exported metrics with alerting thresholds.
4. **Cheap fan-out.** Ingest never blocks on the UI. Broadcasts are per-invocation digests (≤ 4/s) and a global list digest (≤ 1/s) that carries only changed summaries; detail topics are only published while someone is subscribed (`Phoenix.Tracker`-style presence check). The list LiveView applies digests in memory; nothing re-queries per event.
5. **Bounded per-stream memory.** Workers keep only the current batch, the counters, and the named-set map (capped; overflow spills to `named_sets`). Idle workers hibernate; finished workers exit after the linger period. 1,000 streams ≈ a few hundred MB.
6. **Postgres layout.** Daily range partitions for segments (retention = drop partition), monthly for invocations, GIN on tags with `jsonb_path_ops`, `fillfactor` tuned for the counter updates on `invocations` (HOT updates), per-table autovacuum settings, `wal_compression`, large `max_wal_size`, checkpoint tuning. Documented in `docs/postgres.md` with a sizing calculator.
7. **Storage math (defaults).** 5k builds/h × 2 MB compressed raw ≈ 10 GB/h ⇒ raw retention of 3–7 days ≈ 1–2 TB; structured data is ~2–5% of that and lives 90 days+. `STORE_RAW_EVENTS=all|logs_only|none` lets an operator trade the Raw tab/reprocessing for disk. Cold tiering to S3 is post-v1.
8. **One BEAM, many processes.** gRPC, workers, writers and LiveView all run in one VM; CPU-bound decoding parallelizes across schedulers naturally.
9. **Graceful shutdown.** Stop accepting new streams, drain writers (flush + commit), close open streams with `UNAVAILABLE` so Bazel retries against the restarted (or another) server. The same sequence is what makes scale-in safe in §13.2.

### 13.2 Multiple nodes (auto-scaling group)

Several identical app nodes behind a gRPC-aware load balancer, sharing one Postgres and one object store. Correctness never depends on the cluster; the cluster only exists for real-time fan-out and job coordination.

**How it behaves**

- **One stream, one node.** Each Bazel invocation is a single HTTP/2 connection; the IngestWorker lives on the node that accepted it. Any balancer that spreads connections works (AWS NLB or ALB gRPC target groups, GCP L4/L7 with HTTP/2 backends, Envoy/Contour/nginx on Kubernetes). No stickiness needed.
- **Reconnects may land anywhere.** Bazel resends from the last un-acked sequence; the receiving node's worker rehydrates from the invocation row (§6 item 6) and continues. Node loss, restarts and scale-in all reduce to "client reconnects elsewhere".
- **Stale workers are fenced by Postgres**, not by a cluster lock: the compare-and-set on `last_event_seq` plus the segment primary key make a late commit from a dying node fail. Built in M1, so single-node installs get it for free.
- **Scale-in is safe.** On SIGTERM a node fails its readiness check, stops accepting connections, drains and commits writers, then closes streams with `UNAVAILABLE`. Requires a termination grace period (≥ 60 s) and connection draining on the balancer. LiveView sessions reconnect to another node on their own (state re-mounts from the URL and DB).
- **Bazel's retry budget is short.** Measured in M0 with Bazel 9.2: with the default `--build_event_upload_max_retries=4` the client gives up after a few seconds of `UNAVAILABLE`, and the build then reports "The Build Event Protocol upload failed" (the build itself still succeeds). With `--build_event_upload_max_retries=10` a server that was down for ~2 s got the full stream resent and the upload completed. Consequences: (1) the documented `.bazelrc` raises the retry count; (2) single-node restarts must be fast (release boot is ~1 s; there is no compile step in production), and the drain must close streams *only after* the new process can accept, which for a single node means a blue/green swap behind the proxy or accepting a short window of failed uploads during upgrades; (3) in multi-node mode the balancer must stop routing to a draining node before it closes streams, so retries land on a healthy node.
- **The ceiling moves to Postgres.** Adding nodes scales decoding, connection count and LiveView fan-out; write throughput is bounded by the one database. Beyond the §13.1 envelope × nodes: a larger Postgres, then raw segments written directly to the object store with only metadata in Postgres (segments are immutable blobs, so this is natural), then read replicas for dashboards.

**What multi-node mode requires**

| Concern | Single node | Multi-node |
|---|---|---|
| Real-time fan-out | `Phoenix.PubSub` local | libcluster (`CLUSTER_STRATEGY=dns|ec2|k8s`) + PubSub PG2 over distributed Erlang; "publish only while watched" via `Phoenix.Tracker` (cluster-aware CRDT), or always publish the cheap per-invocation digest |
| Blob store | disk or S3 | S3-compatible required (`BLOB_STORE=s3`); disk is refused when clustering is enabled |
| Background jobs | Oban | Oban (unique jobs + cron run exactly once cluster-wide: retention, partition maintenance, profile parsing) |
| API-key cache invalidation | local PubSub | cluster PubSub, plus the 30 s TTL as a fallback |
| Per-key rate limits | exact | approximate: per-node limit ÷ node count, or shared counters in Postgres for the few limits that must be exact |
| DB connections | one pool | nodes × pool ≤ `max_connections`; PgBouncer (transaction mode) for large groups |
| Sessions / auth | signed cookie | unchanged; no sticky sessions |
| Load balancer | any | HTTP/2 end-to-end for gRPC; websocket support for LiveView; idle timeout longer than the longest quiet gap in a build (analysis can go minutes without an event) or clients set `--grpc_keepalive_time=30s` |
| Health | `/health` | `/health/live` (process up) and `/health/ready` (DB reachable, not draining) for the balancer and orchestrator |
| Scaling signal | — | CPU plus custom metrics: open streams, writer queue depth, ack p99 |
| Load testing | §15.1 profiles | same profiles across 3 nodes, with one node scaled in mid-run and the correctness oracle proving zero loss |

Multi-node is a documented, load-tested **deployment mode**, not a separate product: the default `docker compose` stays single-node; the examples below enable `CLUSTER_STRATEGY` and S3.

### 13.3 Reference deployments (both shipped in M7, in `deploy/`)

**Kubernetes** (`deploy/kubernetes/`, plain manifests + a Helm chart in M8)
- `Deployment` with a headless `Service` for node discovery (`CLUSTER_STRATEGY=k8s`, libcluster `Kubernetes.DNS` strategy) and `RELEASE_COOKIE` from a `Secret`.
- Two `Service`s: gRPC (`appProtocol: grpc`, HTTP/2) and web; Ingress examples for nginx-ingress (`backend-protocol: GRPC`), Contour/Envoy and AWS Load Balancer Controller (ALB gRPC target group for `:1985`, HTTP target group with websocket support for `:4000`).
- `readinessProbe` → `/health/ready`, `livenessProbe` → `/health/live`, `terminationGracePeriodSeconds: 90`, `preStop` sleep so the balancer deregisters before drain begins, `PodDisruptionBudget` (min available 1), anti-affinity across zones.
- `HorizontalPodAutoscaler` on CPU plus custom metrics via Prometheus adapter (open streams, writer queue depth, ack p99).
- Postgres external (RDS/Cloud SQL/operator), PgBouncer sidecar or service optional, S3-compatible bucket with IRSA/Workload Identity, migrations as a `Job`/init container guarded by Oban-style advisory lock.

**EC2 auto-scaling group** (`deploy/aws-asg/`, Terraform)
- Launch template running the container (or the release) under systemd with `ExecStop` honoring `SHUTDOWN_DRAIN_SECONDS`; ASG with lifecycle hooks: `Terminating:Wait` gives the node time to drain before the instance is removed.
- `CLUSTER_STRATEGY=ec2` (libcluster EC2 tag strategy via the instance metadata service, IAM permission `ec2:DescribeInstances`) and `RELEASE_COOKIE` from Secrets Manager/SSM.
- NLB with TCP passthrough (TLS at the node) or TLS termination with ALPN `h2` for `:1985`; ALB with websocket support for `:4000`. Target-group deregistration delay ≥ drain time; idle timeout raised for long quiet builds.
- Target-tracking scaling on CPU plus CloudWatch custom metrics published from `/metrics` via the CloudWatch agent (open streams, ack p99).
- RDS Postgres (Multi-AZ), optional RDS Proxy or PgBouncer instance, S3 bucket via instance role; migrations run by a one-off `mix bes.migrate` on a bastion/CI or by the first booting node under an advisory lock.

Both examples are exercised by the multi-node load profile in §15.1 (three nodes, scale-in, node kill) before release.



---

## 14. Configuration, deployment, operations

Env vars (`config/runtime.exs`): `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT` (4000), `BES_GRPC_PORT` (1985), `BES_GRPC_TLS_CERT/KEY`, `BES_INGEST_AUTH`, `AUTH_MODE`, `OIDC_*`, `ADMIN_EMAILS`, `BLOB_STORE=disk|s3`, `BLOB_DIR`, `S3_*`, `RETENTION_DAYS`, `RETENTION_RAW_DAYS`, `BES_STREAM_IDLE_TIMEOUT`, `BES_WRITER_SHARDS`, `BES_WRITER_FLUSH_MS`, `STORE_RAW_EVENTS`, `LIMITS_*` (per-key defaults), `KEY_ROTATION_GRACE_DAYS`, `CLUSTER_STRATEGY` (none|dns|ec2|k8s) + strategy-specific vars, `RELEASE_COOKIE`, `SHUTDOWN_DRAIN_SECONDS`, `CAS_SINK_ENABLED`, `CACHE_ENDPOINTS` (JSON: host → headers), `PUBLIC_URL` (used in `--bes_results_url` hints).

Deliverables: multi-stage Dockerfile (release, non-root), `docker-compose.yml` (app + Postgres), Helm chart (later), `mix release` with migrations on boot (`Bes.Release.migrate`), health endpoints, structured logs, Prometheus metrics, `mix bes.replay` (fixture → live server), `mix bes.gen_key`.

Small installs run fine on 2 vCPU / 4 GB + a modest Postgres; the §13.1 envelope needs the larger sizing described there; multi-node sizing follows §13.2. All are documented with a sizing table.

---

## 15. Testing strategy

**Coverage requirement: 95% line coverage or higher, enforced.** `mix coveralls` (excoveralls, MIT) with `minimum_coverage: 95` runs inside `mix precommit` and in CI; a PR that drops below fails. Generated protobuf modules (`lib/conveyor_proto/`), test support files and the release/telemetry boilerplate are excluded from the denominator because they contain no logic of ours. Every milestone's acceptance implicitly includes "coverage stays ≥ 95%", so tests are written with the feature, not after: the normalizer, query compiler, ANSI renderer, profile summarizer and LiveViews all get unit or LiveView tests as they land, and the replay tool plus recorded fixtures drive the gRPC and ingest paths end to end.

- **Fixtures**: record real streams with `bazel build/test … --build_event_binary_file=x.bep` (varint-delimited `build_event_stream.BuildEvent`) from small sample workspaces: success, build failure, test failures + flaky, aborted/interrupted, remote cache hits, `--build_event_publish_all_actions`, huge log, Bazel 7/8/9 versions. `mix bes.replay` wraps them into `OrderedBuildEvent`s + lifecycle events and streams over real gRPC at configurable speed; also the load-test tool (N parallel replays).
- **Unit** (the bulk of the 95%): normalizer (event → DB ops), query parser/compiler (property tests for round-trips), ANSI renderer, trace-profile summarizer, tag merging.
- **Integration**: gRPC end-to-end with retry/duplicate/out-of-order cases; disconnect + reconnect; auth failures; CAS sink write/read.
- **LiveView**: list filtering/live insert, detail tabs, log streaming, settings flows.
- **Real Bazel in CI**: GitHub Actions job runs bazelisk on a tiny workspace against the server container and asserts the invocation appears with expected status and counts (matrix over Bazel 7.x/8.x/9.x).

### 15.1 Load testing (first-class deliverable)

- **`bes_loadgen`**: a standalone Elixir escript (also a `mix` task) that replays recorded fixtures through the real gRPC client as many concurrent "machines". Knobs: concurrent streams, builds per minute, time-speed factor, fixture mix (small/large/log-heavy/test-heavy), per-key distribution, network jitter, chaos (drop connections mid-stream at a rate, pause/resume, send duplicates, restart the server on a schedule). It reports ack latency percentiles, events/s, bytes/s, stream failures, and total wall time.
- **Correctness oracle**: every replayed event carries a deterministic identity (invocation id + seq + hash). After a run, `mix bes.verify_load` proves each event is persisted exactly once, every invocation reached the expected final status and counters, and no duplicates or gaps exist — including runs with server restarts and forced reconnects. This is the "no lost events" test.
- **Profiles**: (a) steady state at the §13 envelope for 1 hour; (b) burst 3× for 5 minutes; (c) 1,000 idle-then-active streams; (d) log flood (single build emitting 1 GB); (e) restart storm; (f) Postgres restart/failover mid-load; (g) UI load: 200 LiveView clients on the list + 50 on live detail pages while (a) runs; (h) multi-node: profile (a) across 3 nodes behind a balancer, scale one node in and back out mid-run, kill one node outright, and verify zero loss and correct final states.
- **Observability during runs**: Prometheus metrics (ack latency histogram per key, writer queue depth and flush size, transaction duration, DB pool wait, BEAM memory/run-queue, mailbox sizes) + a Grafana dashboard JSON in `docs/`; an admin "System" live page shows the same numbers in-app.
- **Cadence**: run on every PR at a small size (10 streams, 2 minutes) as a regression gate on ack p99 and zero loss; nightly at full envelope on a fixed VM size, results committed to `docs/perf/`. M7 is the campaign that first hits the envelope; after that it is a gate.

---

## 16. Licensing and originality

- Our code: MIT. Ship `LICENSE`, `THIRD_PARTY_NOTICES.md` listing vendored Apache-2.0 protos (Bazel, googleapis, remote-apis) with their notices preserved under `priv/protos/`.
- All dependencies above are MIT/Apache-2.0; avoid GPL/AGPL libraries (e.g. no AGPL chart libs). Tailwind (MIT), Heroicons (MIT), fonts via self-hosted OFL faces if any.
- Implement from Bazel's protos, the BEP docs, and the gRPC spec only; do not consult BuildBuddy/other BES implementations' source while writing code (independent implementation, defensible provenance).

---

## 17. Milestones

Rough sizes assume one engineer working with AI assistance; each milestone ends with something demoable.

| # | Milestone | Scope | Acceptance |
|---|---|---|---|
| M0 ✅ | Bootstrap + protocol spike (≈1 wk) | `mix phx.new` (LiveView, Postgres, Tailwind), vendor + compile protos, gRPC endpoint with `PublishBuildEvent`, ack loop, dump decoded events, replay tool, fixtures recorded with Bazel 9.2 locally, verify elixir-grpc 1.0 on OTP 29 and which BEP files `minimal` upload actually uploads. | `bazel test //... --bes_backend=grpc://localhost:1985 --bes_results_url=http://localhost:4000/invocation/` finishes with no BES warnings; server logs every event; killing/restarting the server mid-build resumes cleanly. |
| M1 ✅ | Ingest + persistence + scale foundation (≈2–3 wks) | Projects + API-key interceptor (scoped keys), IngestWorker, normalizer for all payloads in §2.2, segment storage, sharded group-commit writers, dedup/ordering, DB fencing (compare-and-set), graceful drain on shutdown, finalization, idle timeout, lifecycle RPC, secret scrubbing, Oban, `mix bes.gen_key`, telemetry, `bes_loadgen` v1 + correctness oracle. | Fixture replays produce correct rows/counters; retry/duplicate/restart tests pass with zero loss; 200 concurrent replays at 10× speed sustain 10k events/s with ack p99 < 150 ms on a laptop. |
| M2 ✅ | Builds list + detail (≈2 wks) | Project switcher, list with live updates, cursor pagination, basic filters; detail Overview, Log (ANSI, virtualized, live tail, seekable segments), Targets, Tests, Actions, Details, Raw events; `--bes_results_url` landing. | Watching a build live in the UI: appears on start, log streams, targets/tests populate, status flips on finish; list stays smooth with 1,000 in-progress builds. |
| M3 ✅ | Tags + query language + facets (≈1 wk) | Tag merge pipeline, `tag_keys`, parser/compiler, search box with autocomplete, facet sidebar, shareable URLs, segments (per project). | Queries from §7 all work; `--build_metadata` keys are filterable minutes after first use with no schema change. |
| M4 ✅ | Metrics + dashboard (≈2 wks) | BuildMetrics/BuildToolLogs persistence, Metrics tab, dashboard panels of §11 with segment comparison and all-projects scope, Tests page (flaky/slowest). | p50/p90/p99 by Local vs CI, cache hit trends, failure breakdown render for a 1M-invocation synthetic dataset < 1 s per panel. |
| M5 ✅ | Artifacts + timeline (≈2–3 wks) | Blob store (disk/S3), bytestream fetcher with per-project cache credentials + SSRF guard, HTTP upload API + wrapper script, optional CAS sink, Tier A timeline (live), Tier B profile timeline (worker parse + canvas), profile summary job, test.log/test.xml viewing. | Profile timeline for a 100k-event profile pans/zooms at 60 fps; live Tier A timeline grows during a build; test logs open from the Tests tab. |
| M6 ✅ | Web auth + security hardening (≈1–2 wks) | OIDC (Okta verified + Keycloak/Dex in tests), sessions, roles, project restrictions, admin settings gating, key rotation UI + expiring-key alerts, audit log, per-key limits, CSP/headers, `sobelow`/deps audit in CI, threat model doc. | Login via Okta; viewer cannot reach Settings; rotate a key with both old and new working during grace; scrubbing tests prove no header secrets reach disk. |
| M7 (done on laptop hardware 2026-09-19; reference-hardware rerun pending) | Scale campaign + multi-node mode (≈2–3 wks) | Run the §15.1 profiles against the §13.1 envelope on the reference hardware; partitioning + Postgres tuning; fix everything found (GC, mailbox growth, pool sizing, LiveView fan-out). Then multi-node: libcluster + PubSub PG2, `Phoenix.Tracker`, S3 requirement, readiness/liveness endpoints, cluster-wide key-cache invalidation, the Kubernetes manifests and the EC2 ASG Terraform from §13.3, the 3-node load profile with scale-in and node kill on both platforms. Publish results; small profile as PR gate, full profile nightly. | Single node: 1,000 streams, 30k events/s, ack p99 < 250 ms, zero loss through restart storm and DB restart; UI responsive with 200 clients. Three nodes: ≈2.5× single-node ingest with the same p99, zero loss through scale-in and a killed node. |
| M8 | Ops + release (≈1–2 wks) | Dockerfile, compose, release migrations, retention jobs (partition drop), health/metrics + Grafana dashboard, docs (quickstart, `.bazelrc` recipes, OIDC guides, CI recipes, sizing, security), Bazel-in-CI e2e matrix, v0.1.0 under MIT. | `docker compose up` → create project + key → point Bazel → see builds, within 10 minutes following README. |

**After v1**: cold tiering of segments to the blob store; hourly rollups; raw segments written directly to object storage with metadata only in Postgres; read replicas for dashboards; invocation comparison (diff two builds: targets, durations, cache misses); Slack/webhook notifications on failures; GitHub/GitLab status and PR annotations; per-target duration history; remote execution events (`build_execution_event`); organizations above projects (true multi-tenancy); personal API keys; SQL export / OpenTelemetry export; Helm chart.

---

## 18. Proposed repository layout

```
bes/
  mix.exs, config/{config,dev,test,prod,runtime}.exs
  lib/bes/                      # core domain (no web/grpc deps)
    application.ex
    repo.ex
    ingest/{worker,worker_supervisor,normalizer,batch,writer,writer_pool,scrub,tags,status}.ex
    projects/{project,membership}.ex
    invocations/{invocation,target,test_result,action,metrics,queries}.ex
    query/{parser,ast,ecto}.ex
    artifacts/{fetcher,bytestream_client,blob,blob/disk,blob/s3,profile,profile/summary,junit}.ex
    metrics/{dashboard,percentiles,tests}.ex
    accounts/{user,api_key,api_key_cache,session,audit}.ex
    settings/*.ex, retention.ex, telemetry.ex, release.ex
  lib/bes_grpc/                 # gRPC adapters
    endpoint.ex, publish_build_event_server.ex, bytestream_server.ex, cas_server.ex,
    capabilities_server.ex, interceptors/{auth,logging}.ex
  lib/bes_proto/                # generated protobuf modules (checked in) + priv/protos/*.proto
  lib/bes_web/                  # Phoenix
    endpoint.ex, router.ex, auth/{plug,oidc_controller}.ex
    live/{builds_live,invocation_live/{show,tabs/*},dashboard_live,tests_live,settings_live/*}.ex
    components/{core,charts,status,tags,timeline,log}.ex
    controllers/{api,artifact,health}_controller.ex
  assets/js/hooks/{timeline,log_terminal,chart,autocomplete}.js
  priv/repo/migrations/, priv/static/
  test/{fixtures/bep/*.bep, support/replay.ex, ...}
  loadgen/                      # bes_loadgen escript: replay at scale, chaos, verify oracle
  tools/{bazel_wrapper.sh, bes-upload-profile}
  docs/{quickstart,bazelrc,oidc-okta,ci,architecture}.md
  deploy/{kubernetes/, helm/, aws-asg/}   # §13.3 reference deployments
  Dockerfile, docker-compose.yml, LICENSE (MIT), THIRD_PARTY_NOTICES.md
```

---

## 19. Open decisions

1. **Name** for the project/product (needed for module namespace, Docker image, docs). Placeholder `Bes`.
2. ~~Oban vs in-house jobs~~ — **decided: Oban** (needed for exactly-once jobs across nodes).
3. ~~CAS sink in v1~~ — **shipped in M5** behind `CAS_SINK_ENABLED` (off by default).
4. ~~Blob store~~ — **decided: both**; disk default for single node, S3 required for multi-node.
5. **Projects as the top level** in v1 (recommended) vs. adding organizations above them now.
8. **Reference hardware** for the §13.1 envelope (cloud VM type) so load-test numbers are reproducible. ~~Target platform for the multi-node example~~ — **decided: both Kubernetes and EC2 auto-scaling group**, shipped together in M7 (§13.3).
9. ~~Raw event retention default: 7 days vs 14~~ — **decided 2026-09-19: 14 days** (`RETENTION_RAW_DAYS=14`; builds themselves keep `RETENTION_DAYS`, to be shipped in M8 with the partition-drop job).
6. **Bazel version floor** (suggest 7.x+; 6.x mostly works but lacks some metrics fields).
7. **Two ports** (gRPC 1985 + web 4000) vs. one multiplexed port (adds complexity with Cowboy/Bandit; recommend two).

---

## 20. Immediate next steps

1. `mix phx.new bes --live`, add `grpc_server`, `grpc`, `protobuf`; vendor protos; generate modules.
2. Implement `PublishBuildEvent` with ack loop; run `bazel build //...` on a sample workspace against it; record fixtures.
3. Write `mix bes.replay`; commit fixtures; then start M1.

---

## 21. Implementation notes (kept current as milestones land)

- **M0 (done).** Bazel 9.2 streams into the server with in-order acks; fixtures recorded for seven scenarios; `mix conveyor.replay` replays them as new builds. Measured Bazel's BES retry budget (§13.2).
- **M1 (done).** Projects and API keys (`conveyor_<id>_<secret>`, sha256 at rest, ETS cache, rotate/revoke/expiry), auth interceptor (`:api_key` or `:none` mode), per-invocation `IngestWorker` (ordering, dedup, backpressure, idle timeout, finalization, linger), `Normalizer` for every BEP payload, secret scrubbing, zstd event/log segments in daily partitions, sharded group-commit `Writer` with compare-and-set fencing and per-batch fallback, Oban with partition maintenance, PubSub digests, `Conveyor.Ingest.Verify` oracle, `--drop-after` chaos in the replay tool, 83 tests at 95.7% coverage. Acks are pipelined through a per-stream `Acker` process (Cowboy accepts replies from any process), which took a 98-event build from 7.7 s to ~70 ms end to end.
- **M2 (done).** App shell with project switcher; builds list (`/`, `/p/:slug`) as a LiveView stream with status filters, cursor pagination and live inserts/updates from ingest digests; invocation page (`/invocation/:id[/tab]`) with header stats, Overview (failure summary, timing with analysis/execution bar, slowest tests, execution and mnemonic breakdowns), Log (virtualized terminal viewer: ANSI colours, `\r` and cursor-up emulation so progress lines are overwritten like a terminal, filter, follow-tail, line anchors, 8 MB tail cap with full download), Targets/Actions (streams, live), Tests (grouped attempts with verdicts), Details (command line, options, environment, tags, workspace status, configurations), Events (paged raw BEP with JSON, `.bep` download). Durations and relative times tick client-side. 98 tests, 95.6% coverage.
- **M3 (done).** `Conveyor.Query`: hand-written parser for the §7 syntax, an Ecto compiler (JSONB tag lookups, guarded numeric casts on tags, regex validation so a bad pattern cannot fail the query, negation that includes missing values) and an in-memory evaluator with identical semantics (tested side by side on every operator) so live PubSub inserts respect the active query. Facets from `tag_keys`, search box with datalist autocomplete, shareable `?q=` URLs, and `Conveyor.Projects.Segments` defaults (Local = `ci!=true`, CI = `ci:true`) for the dashboard. 109 tests.
- **M4 (done).** `Conveyor.Metrics.{Scope, Dashboard, Tests}`: window + project + query scopes with segment expansion; summary (counts, success rate, p50/p90/p99, cache hit rate, users), contiguous hourly/daily series with percentiles and cache rate, failure breakdown, strategy mix, builds per user, slowest builds, versions, most failing targets, builds by hour; test health overview (flaky/failing/healthy, p50/max). Dashboard (`/dashboard`, `/p/:slug/dashboard`) with headline tiles, per-segment table, dependency-free SVG charts (stacked bars, lines, hbars), range picker, query filter, debounced refresh on finished builds; Tests page; Metrics tab on the invocation page rendering every BuildMetrics group generically. `mix conveyor.seed` generates synthetic builds; all panels answer in under 10 ms on 5.7k rows. 119 tests.
- **M5 (done).** Tier A timeline (SVG from BEP, live). `Conveyor.Blobs`: content-addressed store keyed by sha256 with `Disk` (atomic rename) and `S3` (hand-written SigV4 over `:httpc`, verified against the AWS reference vector and a fake S3 server) adapters, streaming puts that hash while writing and refuse mismatched digests, spool file for unknown-digest streams, `blobs` table with TTL/pin, daily `BlobMaintenance` prune. `Conveyor.Artifacts`: resolves BEP file maps (store first, then `ByteStream.Read` from the URI host only when that host is a configured project cache endpoint with its headers/TLS — the allow-list is the SSRF guard), profile fetched by an Oban job at finalization (`FetchProfile`: unavailable for `file://`/unconfigured hosts, retried on transport errors), `invocation_artifacts` for named files. gRPC endpoint also serves `ByteStream` (Read always; Write/QueryWriteStatus with `CAS_SINK_ENABLED`), `ContentAddressableStorage` (FindMissing/BatchUpdate/BatchRead, 4 MB batches), `Capabilities` (cache-only sha256) and `ActionCache` (always miss, refuse updates) so `--remote_cache=grpc://conveyor:1985 --remote_upload_local_results=false --remote_build_event_upload=minimal` uploads exactly the profile, test.log and test.xml (verified with Bazel 9.2: GetCapabilities + 3 ByteStream writes; other outputs get bytestream URIs but are not uploaded). HTTP upload API (`PUT /api/v1/invocations/:id/artifacts/:name`, `PUT .../bep`, upload-scoped keys, `tools/bes-upload-profile`). `Conveyor.Profile` streams gzipped trace JSON object by object and summarizes (phases, by category/mnemonic, critical path, 50 longest, counter peaks) into `invocation_metrics.profile_summary` (`ProfileSummary` job). Timeline tab: canvas profile timeline (Web Worker parse into typed arrays with main-thread fallback, lanes per thread, zoom/pan/tooltip/click details/search/category filter/critical-path toggle/counter strips/phase markers) + summary panel + hints, BEP view folded beneath. Tests tab views test.log and JUnit test.xml (`Conveyor.Artifacts.Junit`, SAX with external entities off) fetched on demand. 178 tests, 95.6%.
- **M6 (done).** Settings page (projects, API keys shown once with a bazelrc line, rotate with grace, revoke, expiring banner, cache endpoints, per-project allowed groups, audit log). `Conveyor.Accounts`: `AUTH_MODE=open` (everyone views; `ADMIN_TOKEN` unlocks Settings) or `oidc` (assent: discovery, code + PKCE, state/nonce in session, RS256 ID tokens, users upserted per login, roles from `ADMIN_EMAILS`/`OIDC_ADMIN_GROUPS`, `ALLOWED_EMAIL_DOMAINS`); `Scope` from the session drives a browser plug, `live_session` on_mount hooks (`:default`/`:admin`), project visibility by identity-provider groups and 404s for out-of-scope invocations/downloads; tested against an in-process fake OIDC provider (`test/support/fake_oidc.ex`). `Conveyor.Audit` (sign-ins/failures, unlocks, key/project/endpoint/group changes, uploads). `Conveyor.Limits`: concurrent streams per key (monitor-released slots, `RESOURCE_EXHAUSTED`), events/s per key (token bucket that slows senders, never fails streams), log bytes per invocation (truncation marker); per-key overrides in `api_keys.limits`. Nonce CSP + security headers plug, `FORCE_SSL`, sanitized artifact content types, no dynamic atoms. `sobelow --exit` and `deps.audit` in `mix precommit`, GitHub Actions CI (`.github/workflows/ci.yml`), `docs/security.md` threat model. 197 tests, 95.8%. Not built: a UI to edit per-key limits (config + `Projects.update_api_key_limits/2` only).
- **M7 (done 2026-09-19, laptop; reference-hardware run and the 200-viewer UI test remain).** `Conveyor.Loadgen` + `mix conveyor.loadgen` + `bes_loadgen` escript (fixtures pre-encoded, jitter, drops, duplicates, client-observed ack percentiles, `--verify` oracle); server ack latency telemetry and Prometheus `/metrics` (ack histogram, committed events/batches, writer flush duration/events, workers, streams, DB query/queue time, VM). Cluster formation via libcluster (`CLUSTER_STRATEGY=k8s|dns|ec2|epmd`, own EC2 tag strategy on `Conveyor.Aws` with IMDSv2 role credentials, also used by the S3 adapter), `/health/live|ready`, SIGTERM drain (`SHUTDOWN_DRAIN_SECONDS`), release config, Dockerfile, compose, Kubernetes manifests, EC2 ASG Terraform. **Measured (laptop, prod build, Postgres in Docker, generator on the same machine):** 200 streams → 2000/2000 builds, 4.3k events/s, 0 missing acks, ack p50 1.1 s / p99 3.3 s; 500 streams → 2.7–2.9k events/s, p99 14 s, lifecycle RPC deadline failures; 1000 streams → client send timeouts. Attribution: Postgres 1–4 % CPU, server ≈2 cores, load generator 7–10 cores → the numbers measure the generator, not the server; more writer shards changed nothing; DB pool queue time < 5 ms. **Rerun with the pre-encoded generator (server ≈2.7 cores vs generator ≈3.3):** 200 streams → 4.3k events/s, ack p50 0.87 s / p99 2.9 s; 500 → p99 8.8 s; 1000 (drops + duplicates) → 3.6k events/s, 0 missing acks, p99 16 s. Writer flush histogram: ≈175 events per group commit, median 250–500 ms, 12 % over 1 s, Postgres 1–4 % CPU and pool queue < 5 ms → the ceiling is time spent per group commit inside the transaction (many statements per batch: segment inserts with zstd, target/test/action upserts, fenced invocation update), i.e. ≈400 events/s per shard × schedulers. Grouping the segment inserts (one `insert_all` per table per group, zstd before the transaction) gave p99 2.9→2.7 s at 200 streams and 8.8→6.8 s at 500 with flush durations almost unchanged, so the remaining cost is the per-batch upserts (targets/tests/actions/tag_keys/metrics + fenced update, up to ~8 statements per batch) and BEAM-side work. Next: `:eprof` one writer shard at saturation before more restructuring; then group the upserts too (rows across batches per table, conflict targets unchanged), raise `INGEST_BATCH_MAX_EVENTS`/`INGEST_BATCH_FLUSH_MS` to grow groups, `:eprof` a writer shard at saturation; then the 3-node epmd run with node kill (loadgen `--hosts` spreads streams; add `--retries` reusing invocation ids so killed-node builds resume elsewhere), publish results on reference hardware (open decision). **Profiling session (2026-09-19, laptop, 200 streams × 10k builds):** `:eprof` on one writer shard showed ≈5 % BEAM work (mostly Jason encoding of map columns) and ≈95 % waiting on Postgres; `pg_stat_activity` sampling showed >90 % of active backends blocked on row locks in the `tag_keys` upsert (every group transaction touched the same per-project tag rows and held them for the whole commit). Fixes, each measured: (1) tag counts out of the transaction → ack p50 807→330 ms, p99 2.7 s→0.97 s, 6.4k→12.6k events/s; (2) dropping the unused `(status, last_event_at)` index + `fillfactor 70` (every per-batch update was non-HOT; 3 %→38 % HOT, the ceiling since first and last updates change indexed columns) → p99 0.89 s; (3) one statement per table per group (≈47→≈23 statements per flush; Postgres round trip 0.6 ms idle / ≈3 ms under load through Docker Desktop) → p99 0.76 s; (4) `Conveyor.Ingest.TagCounter` (one sorted upsert per node per `INGEST_TAG_FLUSH_MS`), insert-first invocation creation with RETURNING, and no finalize read unless a profile was referenced (three full-row reads of ≈21 KB `options` per build) → p50 ≈260–290 ms, p99 ≈570–910 ms across identical runs (run-to-run noise ≈±20 % on the laptop), 13–15k events/s, 0 missing acks. Remaining attribution: Docker Desktop's VM has 2 vCPUs and Postgres runs at 125–130 % of them mid-run (the earlier "Postgres idle" reading was taken after the runs ended); a fenced update costs 0.4 ms idle vs 8 ms under load, i.e. queueing, and `synchronous_commit=off` changed nothing (p99 0.70 s). Further laptop runs need more VM CPUs or a native Postgres; the reference-hardware run remains the real envelope. Optional next cut: batch the fenced updates of batches sharing a dirty-column set into one `UPDATE … FROM unnest(...)` (≈12→2 statements per flush). **Log viewer at scale (2026-09-19):** replaced the 8 MB socket payload with a streamed download + Web Worker engine (paged UTF-8 buffer, terminal emulation on bytes, incremental filter, offset-spliced live appends); 50 MB curses log loads in 0.2 s at 127 MB RSS with sub-ms line fetches — the log tab no longer degrades with log size up to the 256 MB ingest cap. **3-node kill test (2026-09-19, laptop, epmd cluster of three prod servers on one Postgres):** 150 streams spread over the nodes with `--retries 5`, one node killed with SIGKILL 15 s in → 6000/6000 builds ok, 340 retried onto the survivors with the same invocation id (resumed from the committed sequence, duplicates acked), 0 missing acks, oracle verified 6000/6000, no fenced writes on the survivors; ack p50 141 ms / p99 578 ms at 14.2k events/s. Storage tuning shipped: autovacuum 2 % on invocations, LZ4 on the large jsonb columns, EXTERNAL storage for the zstd segment payloads, and the unused structured command lines (~85 % of `options`) no longer stored. **Realistic-rate run (2026-09-19):** 1,000 concurrent streams paced at one event per 500 ms on one laptop node (1,000 events/s, builds of 6–48 s) → ack p50 75 ms / p90 90 ms / p99 146 ms / max 264 ms, 0 missing acks, oracle 1500/1500; ≈0.9 MB RSS per concurrent stream (workers + one HTTP/2 connection each; 30 s linger keeps finished workers briefly). The BEAM showed 110–530 % OS CPU at under 1 % real scheduler utilization (busy-wait), so the release now runs with `+sbwt none` (also keeps the CPU-based HPA honest). The generator previously read acks only after sending everything, which made paced runs report ack latency ≈ build length; it now reads them concurrently like Bazel.
- **M8 (in progress, 2026-09-19).** Build retention job (`RETENTION_DAYS`, default 90, nightly batched deletes with cascade and facet rebuild) beside the raw-segment partition drops (`RETENTION_RAW_DAYS`, default 14, decided); Grafana dashboard; docs (production, bazel, ci, auth) and README quick start; Bazel end-to-end workflow with a 7.6.1 / 8.3.1 / 9.2.0 matrix and `mix conveyor.e2e_check` — all three verified locally against a dev server; CHANGELOG and `v0.1.0` tag. Then the docs site (MkDocs Material on GitHub Pages: home, quick start, Bazel, CI, architecture, design decisions, scale, production, Kubernetes/Helm, configuration reference, auth, security, cache endpoints, operations, development), the Helm chart (`deploy/helm/conveyor`), and the release workflow publishing the multi-arch image and the chart to GHCR on tags. Repository: github.com/erneestoc/conveyor. Later the same day: query fuzzing, multi-project and seeded smoke tests; Playwright browser suite (found the facet `phx-value-value` shadowing bug); timeline v2 (flame rows, minimap, range zoom, keyboard, per-action phase breakdown, where-time-went panel, server-side phase totals, seeded synthetic remote-execution profiles).
- **Cache endpoint connection model (post-M5 adjustment, 2026-09-19):** endpoint override, TLS modes (plaintext / system roots / custom CA / mTLS from secret files), bearer token; verified against an mTLS gRPC listener in tests; `docs/cache-endpoints.md`.
- **Learned in M2/M3.** The segment partition day must come from the row's `inserted_at`, never from `started_at`, because the Started event rewrites `started_at` (a build ingested just after midnight UTC became unreadable). Bazel names the profile `command-<uuid>.profile.gz`.
- **Learned in M1.** `TargetConfigured` ids carry no configuration, so targets are keyed by label+aspect. Bazel 9 names the profile `command-<uuid>.profile.gz`. `CREATE TABLE IF NOT EXISTS … PARTITION OF` still races between two booting nodes and must tolerate `duplicate_table`. A finish lifecycle event arriving after the worker exited must not start a new worker (it did, and the worker lived until the idle timeout).

## 22. M9 proposal (2026-09-19): questions still unanswered

Agreed direction with the user: (1) explain rebuilds from input digests, (2) browser tests for settings and auth, (3) a better dashboard. Use cases: local developer builds, RBE in CI, fleet/platform views.

**Local builds.** Why did target X rebuild? (input-digest diff against the previous run of the same target; non-hermetic targets whose digests change on identical sources). Why is my incremental build slow? (analysis vs execution split, Skyframe invalidation counts, cache hit local vs remote). Is my machine the limit? (profile CPU/memory counters, sandbox setup vs execution). Did I break it or is it flaky? (test history, same failure on main).

**RBE in CI.** Where does wall time go per build and over time (cache check / upload / queue / execute / download, now available per build via profile summaries, not yet trended). Is the cache working (hit rate by mnemonic and by target over time, top missing targets, misses explained by digests). Queue time trend as an RBE capacity signal. Bytes up/down per build. Regressions per target on main week over week. Flaky tests blocking merges and retry counts. Builds in progress and p95 per pipeline (from tags).

**Fleet.** Bazel version adoption; client config drift (builds missing `--remote_cache`, unusual flags) detected from parsed options; build minutes and cache usage per team for cost attribution.

**Dashboard v2.** Saved segments (any query) and side-by-side segment comparison; stacked phase-over-time chart; cache hit rate by mnemonic and a top-missing-targets table; regression list (targets whose p50 rose >20 % vs the previous period); build minutes per day; queue-time trend; time-of-day heatmap. Grooming: hover tooltips with exact values on the SVG charts, period-over-period deltas on stat tiles, consistent palette and legends, empty and loading states.

**Explain the rebuild (core of M9).** Ingest Bazel's compact execution log (`--execution_log_compact_file`, uploaded through the artifact API or the CAS sink); store per action: target, mnemonic, input path→digest map (deduplicated), output digests, cache status, runner. Diff view on the Actions tab: "rebuilt because these N inputs changed" with paths; dashboard report of non-hermetic targets (same inputs, different outputs or re-executed). Also feeds bytes up/down and cache hit per target.

**Browser tests.** Settings: create project, create/rotate/revoke API key, cache endpoint form with TLS modes; auth: admin token in open mode, OIDC through the fake provider (needs it enabled in dev) or Keycloak in CI.

## 23. M10 (agreed 2026-09-21): project boundary, hardening, plumbing, product separation

Outcome of the AWS trial (docs/scale.md "AWS trial"): the product works on real builds and
real remote execution, and the first production deployment surfaced five defects, all fixed
the same day. Not multi-tenant for sale, but one organization with several products that
must be genuinely separated. The execution order and pass criteria are in HANDOFF §7 "M10":

1. Project as the hard boundary — scoping in the data layer for every read path, per-project
   retention and blob prefix, a router-walking cross-project 404 test.
2. Fragile parts — no stray lifecycle workers, a chaos soak behind the balancer with the
   loadgen and node kills, root cause and alert for the Oban stall.
3. Plumbing — opt-in database TLS, Caddy single-node TLS (drops the NLB), execution-log
   parser interning and caps, a rehearsed backup/restore, Prometheus alert rules.
4. Product separation in the UI — project home, per-project admin groups, compare and
   previous-build confined to project and branch.

Infrastructure rules for the staging stack are in AGENTS.md ("Infrastructure rules").

Progress (2026-09-21/22): item 1 done (scoped reads, router-walking boundary test, blobs
per project under a key prefix, per-project retention, orphan pruning); item 2 (a) and (c)
done — the Oban "stall" was the execution-log parser's exponential list expansion on
input-set DAGs meeting Oban Lifeline's naive rescue (details in docs/scale.md), fixed
with map unions, a parse queue, timeouts and backlog metrics + alert rules; item 2 (b)
run locally with node kills (zero fenced, zero errors), not yet behind the NLB; item 3's
parser and alert-rule bullets landed with 2 (c). HANDOFF §7 has the per-item detail.
