# Scale and measurements

Everything below was measured on a laptop (16-core Apple silicon) with PostgreSQL 17 in
Docker Desktop's 2-vCPU VM and the load generator on the same machine. Numbers are
therefore conservative on the server side and optimistic on nothing. Rerun them on your
hardware with `mix conveyor.loadgen`; the reports are JSON.

## Results

| Scenario | Result |
|---|---|
| 1,000 concurrent streams, one event per 500 ms (realistic builds of 6 to 48 s), one node | ack p50 75 ms, p90 90 ms, p99 146 ms, max 264 ms; 0 missing acks; every build verified |
| 200 streams replaying builds flat out (13 to 15k events/s), one node | ack p50 0.26 to 0.29 s, p99 0.57 to 0.91 s across identical runs |
| 3 nodes, 150 streams, one node killed with SIGKILL mid-run, client retries on | 6000/6000 builds complete, 340 resumed on other nodes, 0 events lost, oracle verified all |
| Memory | about 0.9 MB per concurrent stream plus 150 MB base |
| PostgreSQL | about 1 vCPU per 10k events/s of replay; per-batch invocation update is the main cost |
| Storage | about 27 KB per small build compressed |

The verification oracle checks, for every build, that stored event segments are
contiguous, counts match, log offsets line up and the final status is present. Load runs
use `--verify` so a passing run means exactly-once persistence, not just "no errors".

## What was found and fixed along the way

The profiling round on the writer is recorded in detail in `PLAN.md` §21. In short:

- **Tag facet row locks** serialized every writer shard; over 90 % of active backends
  were waiting on them. Moving the counts out of the transaction cut p99 from 2.7 s to
  under 1 s at 200 streams and doubled throughput.
- **Non-HOT updates**: an unused index on `last_event_at` made every per-batch update
  rewrite six indexes. Dropping it and setting `fillfactor 70` took HOT updates from 3 %
  to the ceiling of about 40 %.
- **Statements per commit**: writing a group table by table instead of batch by batch cut
  round trips per commit in half. Each round trip to Postgres through Docker Desktop
  cost 0.6 ms idle and about 3 ms under load.
- **Three full-row reads per build** carrying a 21 KB `options` column were replaced with
  an insert-first path and a conditional finalize read.
- **The generator** read acks only after sending everything, so paced runs reported ack
  latency equal to build length. It now reads acks concurrently, as Bazel does.

## Log viewer

The build log is the one artifact that grows without bound (up to the 256 MB ingest cap).
Measured on a 50 MB curses-style log with 722k raw lines:

| Step | Time |
|---|---|
| server streams the log (segment by segment, no buffering) | 0.17 s |
| worker ingests it, terminal emulation applied | 0.20 s, 127 MB RSS |
| fetch of 60 on-screen lines | under 0.1 ms |
| filter over the whole log | 9 ms |
| live append while following | 0.03 ms |

## Where the limits are

- **Postgres CPU** is the first ceiling: fenced invocation updates, then row inserts.
  Batching the fenced updates of a commit into one statement is the next known cut.
- **Per-key limits are per node**: with N nodes a key can use N times
  `MAX_STREAMS_PER_KEY`. Route by key at the balancer if that matters.
- **Not yet measured**: the UI with 200 concurrent viewers during ingest (LiveView does
  not run headless, so it needs a browser-side load tool), and the reference-hardware
  envelope.

## AWS trial with real open-source builds (2026-09-20)

Stack: `deploy/trial` (Terraform) — Conveyor 2 × m6g.large behind an NLB with TLS on 443
and 1985, RDS PostgreSQL 17 `db.m6g.large`, S3 blobs; a self-hosted NativeLink v1.7.1
(CAS + scheduler on a c6i.xlarge, 4 × c6i.2xlarge workers) with a private CA served over
TLS; ECS Fargate builder tasks (8 vCPU / 32 GB) running real Bazel builds in three modes
(`local`, `cache` = NativeLink as remote cache, `rbe` = plus remote execution) through a
workload of clean build, no-op rebuild, leaf edit, wide edit, BUILD edit and tests.

Projects: the fixture workspace, `bazelbuild/examples` (cpp-tutorial), `bazelbuild/buildtools`
(Go), `abseil/abseil-cpp`, `protocolbuffers/protobuf`, `TraceMachina/nativelink` (Rust),
`grpc/grpc`.

Results (four waves, about two hours):

| | |
|---|---|
| Invocations streamed | 420 (144 + 96 + 168 in three waves, then grpc) |
| Profiles fetched from NativeLink over TLS with the private CA | 415 of 415 finished builds |
| Execution logs uploaded and parsed | 374 of 420; 30,026 spawns stored |
| Concurrency wave | 28 Fargate tasks at once (168 builds); Conveyor nodes peaked at 66 % CPU, RDS at 16 % CPU with 82 connections, 58 concurrent TLS flows on the NLB |
| grpc `//:grpc++` clean build | 13 min local / cache-miss, **3 m 41 s with 1,706 actions on remote execution** |
| abseil clean build after one warm-up | 672 of 1,177 actions served from the remote cache; tests returned as cached results |
| Remote cache hit rate by mnemonic (wave 2) | GoCompilePkg 99 %, CppLink 96 %, CppCompile 51 %, Rustc 23 % |

What the dashboards showed on real data: the top cache-missing targets were LLVM's
`compiler-rt` builtins and `libcxx` (toolchain builds that every clean build repeats), the
non-hermetic report flagged abseil's test actions (same inputs, different outputs — test
output timestamps), and the phase vocabulary of the timeline (cache check, upload inputs,
queued, remote execution, download outputs) matched NativeLink's real profiles.

Bugs found by the trial and fixed in the same day (each with a test):

- **Profiles from S3 failed to load in the browser** (`ERR_INCOMPLETE_CHUNKED_ENCODING`):
  the download controller peeked at the stream to detect gzip, which consumed the S3
  adapter's one-shot stream. Fixed by deciding from the blob's content type.
- **`force_ssl` at compile time** looped behind a layer-4 balancer and could not be turned
  off at runtime. Replaced by a runtime plug.
- **Lifecycle events behind a balancer**: Bazel's lifecycle RPC and event stream use
  separate connections. A node holding a stray worker started by the attempt-started event
  fenced the attempt-finished commit (builds left `in_progress`) and rejected a retried
  stream with FAILED_PRECONDITION (a 13-minute grpc build's upload was abandoned). Fixed:
  the finish is recorded directly when fenced, and a stray worker resumes from the row
  when a sequence ahead of its own arrives.
- **Execution-log parse jobs orphaned by an instance refresh** stayed `executing`; Oban's
  Lifeline plugin now rescues them.

Known limits recorded for later: NativeLink's Rust remote execution failed with "Invalid
cross-device link" when rustc renames its archive across the worker's mount namespace
(cache mode works); the execution-log parser takes about 6 s for a 2 MB protobuf log on a
laptop, so large logs queue behind the ten Oban slots per node.
