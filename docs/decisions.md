# Design decisions

The choices that shaped Conveyor, with the reasoning, so they are not relitigated by
accident. Dates refer to when the decision was made or measured.

## Acks are the durability boundary

Bazel's protocol lets the server acknowledge events at any time. Conveyor acknowledges
only after the commit, because the alternative (ack on receipt, persist later) turns
every crash into silent data loss that Bazel cannot detect. The cost is latency between
event and ack; the design keeps it low with group commits and was measured at p99
146 ms with 1,000 concurrent streams.

## Fencing instead of cluster locks

A build's stream can land on any node, and a retried stream can land on a different
node while the first worker is still alive. Rather than a distributed lock, every commit
is a compare-and-set on the invocation's `last_event_seq`. The stale worker's commit
fails, it exits, and Bazel's retry continues on the live one. This works with no cluster
membership at all, so a partitioned cluster degrades to slower live updates, not to
corrupted builds.

## PostgreSQL only

No Kafka, no Redis, no search engine. Everything is in one PostgreSQL database with
daily partitions for the bulk data. Operators get one thing to back up and scale, and
the write path stays simple enough to profile. The measured limit is Postgres CPU at
roughly 10k events/s per vCPU, which is far beyond real build event rates.

## Raw events are kept, briefly

The full BEP stream is stored compressed for `RETENTION_RAW_DAYS` (14 by default) so
that any question the UI does not answer today can be answered later, and so the
Events tab and downloads are exact. Normalized rows stay for `RETENTION_DAYS` (90).

## Tag counts are eventually consistent

Facet counts are hints for autocomplete and ordering. Updating them inside the ingest
transaction serialized every writer on the same rows (measured: over 90 % of active
backends waiting on those locks). They are now counted by one process per node and
written once a second, and rebuilt after bulk deletes.

## Structured command lines are not copied

Bazel sends the canonical and original structured command lines, about 70 KB per build
together, and they are shown nowhere the UI could not derive from the parsed options.
They remain in the raw event stream. Dropping the copy cut per-build storage by 40 %.

## No index on columns the per-batch update touches

An index on `last_event_at` made every one of the roughly three updates per build
non-HOT, rewriting six indexes each time. It was never queried. The rule is recorded in
the handoff notes for contributors.

## The log never crosses the WebSocket

Buildkite-style tabs crash on large logs because the whole log lives in the DOM or as
JavaScript strings. Conveyor streams the log over HTTP into a Web Worker that keeps it as
UTF-8 pages plus line offsets, applies terminal emulation on bytes, and hands the page
only the lines on screen. Live appends splice by byte offset. A 50 MB log loads in 0.2 s
and filters in 9 ms.

## Two ports

gRPC (HTTP/2, `1985`) and HTTP (`4000`) are separate listeners rather than one
multiplexed port. Balancers and ingresses handle gRPC differently from browser traffic
(protocol annotations, idle timeouts, body sizes), and separate ports keep each simple.

## Scheduler busy-wait off

The BEAM spins schedulers waiting for work, which showed as over 100 % CPU at under 1 %
real utilization with 1,000 idle-ish streams. The release runs with `+sbwt none`; on a
250 ms ack budget the microseconds it costs are irrelevant, and CPU-based autoscaling
would otherwise scale on nothing.

## Original implementation

Conveyor was written from the Bazel protocol definitions and documentation. No code from
other Build Event Service implementations was read or reused; the vendored `.proto`
files carry their Apache-2.0 notices.

## Still open

- Reference hardware for the published performance envelope.
- A minimum supported Bazel version (7 is the tested floor).
