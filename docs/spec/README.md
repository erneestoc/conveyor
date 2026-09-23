# Ingest protocol specification (TLA+)

`Ingest.tla` models the BES ingest protocol for one invocation: a Bazel-like client that
resends from its last acknowledged event after every lost connection, up to two nodes
each running at most one worker per invocation (load the row, absorb in order, batch,
commit through the compare-and-set fence on `last_event_seq`), acknowledgements that only
travel over the open connection, takeovers, idle exits, and the two lifecycle
notifications landing on any node. Chaos is bounded: connection drops and one commit that
fails for a non-fence reason (a database hiccup after the retries).

Properties checked by TLC:

| Property | Meaning |
|---|---|
| `Durability` | every sequence the client saw acknowledged is committed |
| `KnownCommitted` | no worker believes more is committed than the row holds |
| `Completes` (liveness) | with bounded chaos, the stream finishes and the lifecycle is recorded |

Three configurations, all with two nodes, three events plus the marker, two drops and one
failed commit (about 630k distinct states, a few seconds each):

| Config | Knobs | Result |
|---|---|---|
| `Ingest_fixed.cfg` | the protocol as of the dedup fix (2026-09-23) | all properties hold |
| `Ingest_current.cfg` | the dedup rule the code shipped with: a resend is acknowledged at once when it is below the sequence the worker *expects* | `Durability` violated in 7 steps: absorb 1, drop, reconnect to the same node, resend 1, acknowledged while its batch is still in flight; a failed commit then loses it for good, and Bazel never resends what it believes stored |
| `Ingest_pre_m10.cfg` | the attempt-started notification starts a worker; a fenced finish is not recorded | `Completes` violated: the finish lands on the stray worker's node, is fenced and never recorded (the builds the AWS trial left `in_progress`) |

The fix for the first row is in `Conveyor.Ingest.Worker`: a resend is acknowledged
immediately only when `seq <= committed_seq`; between `committed_seq` and `expected_seq`
the new connection is registered as a waiter on the batch that carries the event, so the
ack follows the commit (`worker_test.exs`, "a resend of an absorbed, uncommitted event").

## Blob lifecycle (`Blobs.tla`)

One digest of one project: upload (object plus a row with a TTL), attach (exists check,
pin, reference insert), TTL expiry and orphan pruning after the grace period. Property
`ReferencedIntact`: a reference always points at a blob whose row and object exist.

| Config | Knobs | Result |
|---|---|---|
| `Blobs_current.cfg` | pin and reference as two statements, pin ignores a missing row; deletion removes the object, then the row | violated in 8 steps: the attacher pins, pruning passes its orphan check and deletes the object, the reference is inserted |
| `Blobs_fixed.cfg` | pin and reference in one transaction and the pin must hit the row; deletion re-checks the pin and the references under the row lock and drops the row before the object | holds |

Fixed in `Conveyor.Blobs` (`pin/2` returns `{:error, :blob_gone}` on a missing row,
`delete_blob/2` locks, re-checks and drops the row first; the explicit `delete/2` forces)
and `Conveyor.Artifacts.attach/4` (one transaction, `{:ok, artifact} | {:error, :blob_gone}`;
a vanished profile blob makes the fetch job retry, an upload answers 503).

## Writer group commit (`Writer.tla`)

One shard, two invocations, stale submissions, the group commit with its per-batch
fallback, tag counts added after the commit. Without chaos every property holds
(`Writer_fixed.cfg`, 686 states): a batch's rows land exactly once and in order, and the
counted tags equal the committed batches. `Writer_current.cfg` adds a lost commit
acknowledgement (the transaction committed, the writer saw an error and retried): the retry
fences, the fallback fails every batch, the clients re-synchronise through dedup, nothing
is lost or duplicated, but the tag counts of that group are never added. Accepted:
facet counts are approximate by design and `Invocations.rebuild_tag_keys!/1` restores them.

## Rollup staleness (`Rollup.tla`)

One project-hour, builds changing while the hour is computed. Property `Fresh`: a row that
passes the staleness check reflects every change. `Rollup_current.cfg` (row stamped when it
is written) fails: a build finishing during the compute is newer than the read but older
than the stamp, so the hour stays wrong until something else changes. Fixed: the stamp is
taken before the read, five seconds early for clock skew (`Rollup.roll!/2`,
`Rollup_fixed.cfg` holds).

## Oban rescue (`Oban.tla`)

One long job with Lifeline's rescue. `OneRun` (never two runs at once) holds when the
job's timeout is shorter than the rescue window (`Oban_fixed.cfg`, 10 < 15 minutes as
configured) and fails otherwise (`Oban_current.cfg`); `oban_rescue_test.exs` pins the
configuration to that order.

## Running

```sh
docs/spec/check.sh                          # every configuration
docs/spec/check.sh Ingest:fixed Blobs:fixed # the ones that must pass
```

Not modelled: retention against live ingest (a deleted build whose stream resumes), and
the drain on shutdown beyond what the ingest model's exits cover.

TLC needs Java and `tla2tools.jar` (`TLA_TOOLS=/path/to/tla2tools.jar`, default
`~/tla/tla2tools.jar` from https://github.com/tlaplus/tlaplus/releases). Re-run the model
when the worker or writer protocol changes; keep the spec's actions aligned with
`worker.ex` (`handle_call({:push, …})`, `takeover/2`, `handle_info({:batch_committed…})`),
`writer.ex` (`fenced_update!/3`) and `ingest.ex` (`lifecycle/2`).

Not modelled: several invocations, the writer's group commit across invocations (the
fence is per row), backpressure, the log cap, retries inside the writer (a `DbFail` is the
exhausted retry), and the contents of events.
