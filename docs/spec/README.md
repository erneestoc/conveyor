# Ingest protocol specification (TLA+)

`Ingest.tla` models the BES ingest protocol for one invocation: a Bazel-like client that
resends from its last acknowledged event after every lost connection, up to two nodes
each running at most one worker per invocation (load the row, absorb in order, batch,
commit through the compare-and-set fence on `last_event_seq`), acknowledgements that only
travel over the open connection, takeovers, idle exits, and the two lifecycle
notifications landing on any node. Chaos is bounded: connection drops and one commit that
fails for a non-fence reason (a database hiccup after the retries) or is lost with its
writer process (`WriterDown`, 2026-11-09: the writer of a live node dies holding the batch,
which did or did not commit; the worker's monitor reports it and the worker stops).

Properties checked by TLC:

| Property | Meaning |
|---|---|
| `Durability` | every sequence the client saw acknowledged is committed |
| `KnownCommitted` | no worker believes more is committed than the row holds |
| `Completes` (liveness) | with bounded chaos, the stream finishes and the lifecycle is recorded |

Three configurations, all with two nodes, three events plus the marker, two drops and one
failed commit (about 920k distinct states, a few seconds each):

| Config | Knobs | Result |
|---|---|---|
| `Ingest_fixed.cfg` | the protocol as of the dedup fix (2026-09-23) | all properties hold |
| `Ingest_current.cfg` | the dedup rule the code shipped with: a resend is acknowledged at once when it is below the sequence the worker *expects* | `Durability` violated in 7 steps: absorb 1, drop, reconnect to the same node, resend 1, acknowledged while its batch is still in flight; a failed commit then loses it for good, and Bazel never resends what it believes stored |
| `Ingest_pre_m10.cfg` | the attempt-started notification starts a worker; a fenced finish is not recorded | `Completes` violated: the finish lands on the stray worker's node, is fenced and never recorded (the builds the AWS trial left `in_progress`) |

The fix for the first row is in `Conveyor.Ingest.Session.push/4`: a resend is acknowledged
immediately only when `seq <= committed_seq`; between `committed_seq` and `expected_seq`
the new connection is registered as a waiter on the batch that carries the event, so the
ack follows the commit (`session_test.exs`, "a resend of an absorbed, unflushed event" and
"a resend of an event at the writer").

The protocol lives in one pure module, so the mapping is by function:

| Action | Code |
|---|---|
| `StartWorker` | `Worker.load_or_create/3` → `Session.loaded/2` |
| `Push` (dedup, `Absorb`, takeover, reject) | `Ingest.push/3` → `Session.push/4`; takeover is the `:reload` effect followed by `Session.loaded/2` |
| `Flush` | `Session.timer(s, :flush)` (or the batch size, or the marker) → `{:submit, batch}` |
| `Commit` | `Writer` (`fenced_update!/3`) → `Session.committed/2`, fenced → `Session.failed/3` |
| `DbFail` | `Session.failed/3` |
| `WriterDown` | the worker's monitor → `Session.writer_down/1` |
| `Exit` | `Session.timer(s, :linger)`; the idle disconnect before it is `Session.timer(s, :idle)` |
| `LifecycleStarted`, `LifecycleFinished` | `Ingest.lifecycle/2` → `Session.lifecycle/3` on a live worker, the row directly otherwise |

`session_test.exs` runs the model's scenarios as tables of inputs and expected effects.

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

Round two (found through `Archive.tla`, 2026-09-26): the model's upload was atomic and
waited for a deletion in flight, which hid a re-upload of the same content. Uploads now
write the object, then upsert the row, at any time. `Blobs_reupload.cfg` (the 0.2.2 code:
the row dropped under the lock, the object after the commit) violates `ReferencedIntact`
in 11 steps: a re-upload writes the object, the deleter drops the row, the re-upload's row
lands, an attacher checks and pins it, and the deleter's object delete (after its commit)
removes the bytes under a fresh reference. `ObjectUnderLock` (in `Blobs_fixed.cfg`): `delete_blob/2`
deletes the object while it holds the row lock and drops the row after, and `pin/2`
checks that the object exists while it holds the lock (`{:error, :blob_gone}` otherwise).
A deleter that dies after the object delete leaves a row without bytes; the pin check
refuses it and the next prune removes it.

## Raw archive write-behind (`Archive.tla`)

One finished build, its daily segment partition, two nodes running `ArchiveRaw`, orphan
pruning, build retention and the partition drop. The archiver reads the segments, puts one
blob (object, then row; the same content always gets the same digest) and records the
reference with `UPDATE … WHERE raw_status = 'segments'`; the loser of that update deletes
its blob through the checked delete. Chaos: archivers crash between any two steps, a
deleter's transaction dies after the object delete, the job does not run for days (a
store outage), a late finish notification touches the row, retention deletes the build.
Properties: `Stored` (every event is in the segments or in the referenced blob) and
`ReferencedIntact`. `RETENTION_RAW_DAYS` = 2, archive delay one day (the target defaults).

| Config | Knobs | Result |
|---|---|---|
| `Archive_fixed.cfg` | drop guard, pinned reference, object deleted under the row lock | holds (11k states) |
| `Archive_current.cfg` | the design as first written (HANDOFF §7): date-only partition drop, plain conditional `UPDATE`, 0.2.2 blob deletion | `Stored` violated in 7 steps: the archive has not run (store outage, or a build that crossed midnight gets one hour of slack) when the partition's date passes |
| `Archive_noguard.cfg` | everything but the drop guard | `Stored` violated the same way: no delay/retention arithmetic survives an outage |
| `Archive_plainref.cfg` | the reference without pinning the row | `ReferencedIntact` violated in 13 steps: put, the node stalls past the pruning grace, prune deletes the orphan, the reference lands on nothing (a later partition drop then loses the events) |
| `Archive_reput.cfg` | 0.2.2 blob deletion (object after commit) | `ReferencedIntact` violated in 16 steps: a crashed archiver's orphan is pruned, the next run re-puts the same digest between prune's commit and its object delete, pins the fresh row and references bytes that are then deleted |

Design changes before any code (`Conveyor.Workers.ArchiveRaw`, `Conveyor.Storage.Partitions`,
`Conveyor.Blobs`): the partition drop skips a day that still holds a finished build with
`raw_status = 'segments'` (the oldest-unarchived gauge alerts instead of data being lost);
the reference is recorded in one transaction that pins the blob (`Blobs.pin/2`, which now
checks the object under the lock); blob deletion as in the Blobs round two above. Out of
the model: builds that never finish are never archived and their segments go with the
partition after `RETENTION_RAW_DAYS`, as before the archive.

## The raw log in blob mode (`RawLog.tla`)

`RAW_LOG=blob` (PLAN §25 step 2): a writer shard on each of two nodes takes the batches
pending on it as one group, registers a fresh key in `raw_log_objects`, writes the group's
bytes to that object and commits the byte-range index rows; the acknowledgement follows
the commit. A batch's row lives in the daily partition of its build's creation day; the
hourly job drops the days older than `RETENTION_RAW_DAYS`, the daily sweep deletes the
registered objects older than that plus a day. Properties: `Readable` (an acknowledged
batch's bytes are readable from its index row's object until the row's partition is
dropped) and `Registered` (every object in the store has a row, so the sweep reaches it).
Chaos: a node dies between any two writer steps (its batches are resent, nothing was
acknowledged), a put fails, a commit fails after the put (an orphan the sweep collects),
both nodes write at once, midnight falls while a batch waits in a writer, and the
partition drop runs late or not at all (a stalled maintenance queue, or the archive's
drop guard keeping the day). `R` = 1, two batches, two objects per writer.

| Config | Knobs | Result |
|---|---|---|
| `RawLog_fixed.cfg` | row before bytes, ack after the commit, the sweep bounded by the oldest live partition | holds (7.4M distinct states, about 15 s) |
| `RawLog_current.cfg` | the sweep as landed on 2026-11-06: age alone (`R + 1` days) | `Readable` violated in 10 steps: a batch of day 0 commits on day 2 into an object registered on day 1; the drop of partition 0 (due on day 2) has not run when, on day 3, the sweep deletes the object under the acknowledged batch's row. In real time the drop (the first hourly run after midnight) and the sweep (04:30) fall on the same day, so only hours of ordering separate them, and the archive's guard, which keeps a day on purpose, removes even that |
| `RawLog_ackonput.cfg` | the ack once the bytes are durable, before the index commit | `Readable` violated in 6 steps: acknowledged with no row to find the bytes by; a failed commit or a crash then leaves them an orphan the sweep collects, and the client never resends |
| `RawLog_rowafter.cfg` | the row registered after the bytes | `Registered` violated in 3 steps: the window in which a crash leaves an object no sweep will ever delete |

The writer and `RawLog.put/2` already did the first two (`store_object!/2` runs before the
transaction, the row goes in before the bytes); the third is the change the model asked
for: `Workers.RawLogSweep` bounds its cutoff by `Partitions.oldest_day/0`, since an
object is registered when its batches commit and so never before their build's creation
day, a partition of day `d` only references objects registered on or after `d`
(`raw_log_sweep_test.exs`).

## Deduplicated input lists (`SpawnInputs.tla`)

Execution-log input lists are stored once per project and digest (`spawn_inputs`) and
referenced by spawn rows. One list, two stores (upsert the list, insert the spawns, commit,
or crash before the commit), retention deleting spawns at any moment, and orphan pruning
(scan for old unreferenced lists, lock the row, re-check, delete). Property `Intact`: a
committed spawn always references a list that exists.

| Config | Knobs | Result |
|---|---|---|
| `SpawnInputs_fixed.cfg` | the upsert takes the row lock (`ON CONFLICT DO UPDATE`), pruning re-checks under the lock | holds |
| `SpawnInputs_nolock.cfg` | `ON CONFLICT DO NOTHING` (no lock) | violated in 11 steps: the prune locks and re-checks an orphan, a store commits a new reference, the prune deletes the list |
| `SpawnInputs_norecheck.cfg` | locked delete that trusts the candidate scan | violated: a reference committed between the scan and the lock is deleted from under |

Implemented in `Conveyor.ExecLog.store!/2` (lists upserted with `DO UPDATE` in the same
transaction as the spawns) and `prune_orphan_inputs/2` (`FOR UPDATE`, re-check, delete);
`spawn_inputs_test.exs` pins the Postgres locking behaviour the fixed configuration relies
on with two connections (`DO UPDATE` blocks a `FOR UPDATE NOWAIT`, `DO NOTHING` does not).

## Writer group commit (`Writer.tla`)

One shard, two invocations, stale submissions, the group commit with its per-batch
fallback, tag counts added after the commit. Without chaos every property holds
(`Writer_fixed.cfg`, 686 states): a batch's rows land exactly once and in order, and the
counted tags equal the committed batches. `Writer_current.cfg` adds a lost commit
acknowledgement (the transaction committed, the writer saw an error and retried): the retry
fences, the fallback fails every batch, the clients re-synchronise through dedup, nothing
is lost or duplicated, but the tag counts of that group are never added. Accepted:
facet counts are approximate by design and `Invocations.rebuild_tag_keys!/1` restores them.

Since 2026-10-01 the implementation's fallback is narrower than the model's: a fenced
group fails only the fenced invocations' batches (from the fenced sequence on) and commits
the rest again as one group, instead of redoing every batch alone. Every batch the model
commits in `Fallback` is still committed or failed-and-resent by the client; the model's
properties (rows land once and in order, counted tags equal committed batches) are
unaffected because the change only removes commits from a round. Re-model if the fallback
ever starts committing batches the group did not contain.

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

## Retention against a live stream (`Retention.tla`)

Retention deletes a build that started before the cutoff while its stream is still live or
about to resume: the worker's next commit is fenced (row gone), the client retries, the
row is created again empty and the resent sequence is ahead of it, so the upload fails for
good and an empty `in_progress` row stays behind (`Retention_current.cfg` violates
`NoZombie`). Fixed: retention skips `in_progress` and `disconnected` builds whose row
changed within two idle windows (`BuildRetention.delete_before/3`, `Retention_fixed.cfg`).

## Running

```sh
docs/spec/check.sh                          # every configuration
docs/spec/check.sh Ingest:fixed Blobs:fixed # the ones that must pass
```

Not modelled: the drain on shutdown beyond what the ingest model's exits cover.

TLC needs Java and `tla2tools.jar` (`TLA_TOOLS=/path/to/tla2tools.jar`, default
`~/tla/tla2tools.jar` from https://github.com/tlaplus/tlaplus/releases). Re-run the model
when the session or writer protocol changes; keep the spec's actions aligned with
`session.ex` (table above), `writer.ex` (`fenced_update!/3`, the delivery contract of
`submit/2`) and `ingest.ex` (`lifecycle/2`).

Not modelled: several invocations, the writer's group commit across invocations (the
fence is per row), backpressure, tenancy (one project), the linger and the resume after an
idle disconnect (all four are table tests of the session), the log cap, retries inside the writer (a `DbFail` is the
exhausted retry), and the contents of events.
