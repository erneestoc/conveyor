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
   invocations in one transaction: the fenced updates on the invocation rows first, then
   one statement per table (segments, targets, tests, actions, metrics) with rows merged
   across batches. Every batch gets one outcome before a deadline (20 s): committed,
   fenced, expired or failed. A group is planned and stored once; if an attempt fails, a
   bounded policy decides what is attempted next (the group without its fenced builds, the
   same group after a wait while the database is unavailable, halves to isolate a row the
   database refuses), so one bad invocation cannot block the others and a failing
   database is not answered with more transactions.
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
| `targets`, `test_results`, `actions`, `invocation_metrics` | normalized rows keyed by invocation, upserted with partial column sets. The file-set graph (`NamedSetOfFiles`, `TargetComplete.output_group`) is not normalized: it stays in the raw BEP stream. The `named_sets` table and `targets.output_groups` column still exist, unwritten, until the release that drops them |
| `event_segments` | the raw BEP stream, zstd-compressed batches, partitioned by day: the bytes themselves (`RAW_LOG=postgres`) or a byte range of a raw-log object (`RAW_LOG=blob`) |
| `log_segments` | the build log text, zstd-compressed batches with byte and line offsets, partitioned by day, in the same two forms |
| `raw_log_objects` | one row per raw-log object in the blob store (`rawlog/<node>/<shard>/<id>`), registered before the object is written so the sweep finds it |
| `tag_keys` | tag facet counts per project, maintained by a per-node counter, rebuilt after deletes |
| `spawns` | one row per spawn of an uploaded execution log: target, mnemonic, cache status, timings, input and output digests, the sorted input list as one compressed blob |
| `blobs` | metadata per `(project_id, digest)`: size, type, origin, expiry, the key prefix the bytes live under |
| `projects`, `api_keys`, `users`, `audit_log`, `blobs`, `artifacts` | control plane |

Raw segments live in daily partitions so retention is a `DROP TABLE`, not a delete. Build
rows are deleted in batches after a longer retention.

### The raw bytes store

A build's raw bytes (the BEP events as sent, the log text) take up to three forms over its
life: segment rows that carry the bytes, segment rows that carry a byte range of a raw-log
object, and, a day after the build finished when `RAW_ARCHIVE_ENABLED` is on, one archived
blob for the events and one for the log. One module, `Conveyor.RawStore`, owns all three
and is the only one that knows which a build is in:

| The store's interface | Who calls it |
|---|---|
| append: `prepare/3`, `append/1` (a group commit's bytes to rows, or to one object and row ranges), `event_segment/3`, `log_segment/3`, `write_mode/0` | the commit pipeline's store step (`Ingest.Writer.Store`), `Ingest.Batch` |
| read: `frames/1`, `bep/1`, `events_page/3` (only the rows that cover the page), `log/1` (size and stream) | `Invocations.events/1`, `events_page/3`, `log/1`, the download controller, the Events tab and log viewer through them |
| compact: `compact_due/2`, `compact/2` (segments and ranges to archived blobs; `docs/spec/Archive.tla`) | `Workers.ArchiveRaw` |
| expire: `expire_partitions/1`, `expire_objects/2`, `expiry_backlog/1`; the date rules are `RawStore.Expiry` | `Workers.PartitionMaintenance`, `Workers.RawLogSweep`, the gauges |
| verify: `audit/1` | `Ingest.Verify`, the one oracle for every form |

Underneath, the object store is one seam, `Conveyor.Blobs.Adapter`, with two kinds of
object in the same backend: content-addressed blobs under a project's prefix, and keyed
objects (the raw log) written whole and durably, read by byte range and deleted in bulk.
`Blobs.Disk` and `Blobs.S3` implement both; the test doubles (`Flaky`, `OneShot`,
`Counting`) wrap the disk adapter, so a store failure is injected at one place for blobs
and raw log alike. `test/conveyor/raw_store_contract_test.exs` states the store's
contract (the bytes appended are the bytes read, in every form and across every
transition) and `raw_store_seam_test.exs` fails when another module starts to select the
object columns or test `raw_status`. Storage per build is about 27 KB
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
ByteStream/CAS server that accepts uploads for referenced digests only. Blobs belong to a
project: they are keyed by `(project_id, digest)` and stored under the project's key prefix
(`<prefix>/<digest>` in S3, `<prefix>/aa/bb/<digest>` on disk; the slug unless changed in
Settings), so one project's data is one prefix that can be listed, lifecycle-ruled or
removed on its own, and projects never share blobs. A nightly job prunes cache uploads no
build pinned within their TTL and blobs whose builds retention has since deleted.

An uploaded execution log is parsed into `spawns`; input sets form a DAG in which the
same file is reachable through many paths, so the expansion unions maps memoized per set
rather than concatenating lists (the list version took minutes on real logs). The Actions
tab diffs each spawn's inputs against the previous build of the same project and branch.

## Auth

Bazel authenticates with per-project API keys (`conveyor_<id>_<secret>`, SHA-256 stored,
cached per node with cluster-wide invalidation). People sign in through OpenID Connect or,
in open mode, read freely and use an admin token for Settings. A project's allowed groups
decide who sees it and its admin groups who administers it at `/p/<slug>/settings`; global
admins do everything. Every read takes the viewer's project set as a SQL restriction, so
the project is a hard boundary rather than a filter in the page. Every admin action is in
the audit log. See [Roles and boundary](roles.md) and [Security model](security.md).

## Clustering

Nodes discover each other through libcluster (Kubernetes headless service, DNS, EC2 tags
or a static list). The cluster carries PubSub and cache invalidation only; ingest
correctness never depends on it. Per-key limits are per node.
