# Architecture

Conveyor is one Elixir/OTP application per node, backed by PostgreSQL and an S3-compatible
blob store. Bazel talks gRPC to it; people talk HTTPS to a Phoenix LiveView UI on the same
node. Nodes are interchangeable: any of them can ingest any build and serve any page.

```
Bazel ──gRPC (PublishBuildEvent)──▶ node A ─┐
Bazel ──gRPC──▶ node B ────────────────────┼──▶ PostgreSQL (builds, targets, tests, events, logs)
Browser ──HTTPS / WebSocket──▶ node C ─────┘         S3 (profiles, test logs, uploads)
                 nodes form an Erlang cluster for live updates and cache invalidation
```

## Ingest pipeline

1. **gRPC server** (`PublishBuildToolEventStream`, bidirectional). The auth interceptor maps
   the `x-api-key` header to a project and its limits. Each stream carries one build's
   events in order, numbered from 1.
2. **Worker** per invocation (a GenServer). It enforces order and deduplicates: an event
   below the expected sequence number is acknowledged immediately, above it is rejected
   with `FAILED_PRECONDITION`. It normalizes each BEP event into changes to the invocation
   row plus rows for targets, tests, actions and named file sets, appends the raw event
   and the log text to the current batch, and applies backpressure when too many events
   are unacknowledged.
3. **Scrubbing** happens before anything is stored: header flags, credentials in URLs,
   `token=` parameters and bearer tokens are redacted from command lines and logs, in the
   raw protobuf as well as the normalized columns. Bazel copies the client environment
   into the command line, so this is not optional.
4. **Batches** close every 50 ms or 500 events or 256 KB. The worker hands a batch to a
   **writer shard** chosen by hashing the invocation id.
5. **Group commit.** Every 20 ms a writer shard commits all pending batches from all its
   invocations in one transaction: one statement per table (segments, targets, tests,
   actions, named sets, metrics) with rows merged across batches, then one fenced update
   per batch on the invocation row. If the group fails, batches are retried one by one so
   one bad invocation cannot block the others.
6. **Acknowledgement.** Only after the commit does the worker ack the batch's sequence
   numbers to Bazel. Acks are the durability boundary; Bazel resends from the last
   unacknowledged event on any retry.
7. **Fencing.** The invocation row carries `last_event_seq`. Every commit does
   `UPDATE ... WHERE last_event_seq = first_seq - 1`; zero rows means another worker (on
   another node, or after a restart) has taken over, and this worker exits so the stream
   fails and Bazel retries. Correct across nodes without any cluster lock.
8. **Finalize.** The final status is written in the batch that carries the end-of-stream
   marker, so the status and the last ack become durable together. The worker lingers
   briefly for late lifecycle events, then exits.

## Storage layout

| Table | Content |
|---|---|
| `invocations` | one row per build: status, timings, counters, tags, options, cache stats. Updated a few times per build (fenced). |
| `targets`, `test_results`, `actions`, `named_sets`, `invocation_metrics` | normalized rows keyed by invocation, upserted with partial column sets |
| `event_segments` | the raw BEP stream, zstd-compressed batches, partitioned by day |
| `log_segments` | the build log text, zstd-compressed batches with byte and line offsets, partitioned by day |
| `tag_keys` | tag facet counts per project, maintained by a per-node counter, rebuilt after deletes |
| `projects`, `api_keys`, `users`, `audit_log`, `blobs`, `artifacts` | control plane |

Raw segments live in daily partitions so retention is a `DROP TABLE`, not a delete. Build
rows are deleted in batches after a longer retention. Storage per build is about 27 KB
for a small build (row 9 KB, raw events 16 KB, log 1 KB) and grows with targets, actions
and log volume.

## Live UI

LiveView pages subscribe to per-invocation and per-project topics on Phoenix PubSub,
which spans the Erlang cluster, so a browser connected to node C sees a build ingested
on node A. Workers broadcast digests at most every 250 ms. The build log is the one thing
that does not travel over the WebSocket: the page fetches it as a streamed download into
a Web Worker that keeps the bytes and does the terminal emulation, and only the visible
lines are ever rendered ([details](scale.md#log-viewer)).

## Artifacts

BEP references files by `bytestream://` URI on the remote cache. Conveyor fetches the
profile and test outputs from the cache endpoint configured per project (with the cache's
own TLS and auth) or receives them directly through its built-in CAS sink, a minimal
ByteStream/CAS server that accepts uploads for referenced digests only. Blobs go to disk
or S3; a daily job prunes uploads no build pins.

## Auth

Bazel authenticates with per-project API keys (`conveyor_<id>_<secret>`, SHA-256 stored,
cached per node with cluster-wide invalidation). People sign in through OpenID Connect or,
in open mode, read freely and use an admin token for Settings. Every admin action is in
the audit log. See [Security model](security.md).

## Clustering

Nodes discover each other through libcluster (Kubernetes headless service, DNS, EC2 tags
or a static list). The cluster carries PubSub and cache invalidation only; ingest
correctness never depends on it. Per-key limits are per node.
