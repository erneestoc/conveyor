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
| `Commit` | `Writer.Transaction.run/3` (the fenced update) → `Session.committed/2`, fenced → `Session.failed/3` |
| `DbFail` | `Session.failed/3` (a failed or expired batch: `Writer.Policy` gave up, or the deadline passed) |
| `WriterDown` | the worker's monitor → `Session.writer_down/1` |
| `Exit` | `Session.timer(s, :linger)`; the idle disconnect before it is `Session.timer(s, :idle)` |
| `LifecycleStarted`, `LifecycleFinished` | `Ingest.lifecycle/2` → `Session.lifecycle/3` on a live worker, the row directly otherwise |

`session_test.exs` runs the model's scenarios as tables of inputs and expected effects.

### Admission (stated, not modelled)

`Conveyor.Admission` (PLAN §26.4) may refuse a stream, a build or the next event of an open
stream. Two invariants hold by construction, and the tests name them:

- **A refused event was never acknowledged.** The event door is asked before the event is
  handed to its session (`PublishBuildEventServer`, `Ingest.push_all/3`): a refused event
  is not absorbed, so no batch carries it and no commit can acknowledge it. The RPC ends
  with UNAVAILABLE and the client resends from its last acknowledgement
  (`admission_end_to_end_test.exs`, "at the deadline an open stream's next event is
  refused").
- **A refusal writes nothing.** A stream refused when it opens took no slot and started no
  session; a build refused at its notification or at its first event has no row created
  for it by that call (same file, "a shedding node refuses a new build and leaves no row").
  A row can still exist for a refused stream when the build's notification was admitted
  earlier or on another node; that is why a node under pressure asks whether the row
  exists before it refuses a stream that starts at sequence 1 (`Ingest.announced?/2`).

In the model's terms a refusal is the `Drop` action chosen by the server at a point where
the node has absorbed nothing new: the connection ends, the client reconnects and resends
from its last acknowledgement. `Durability` and `KnownCommitted` are checked over every
interleaving of `Drop`, so they cover refusals; adding an action that changes no state
would check nothing more. What the model cannot promise for admission is `Completes`: it
holds with *bounded* drops, and a node that sheds for longer than the client's retry
budget fails that upload by design.

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

Code ↔ model since the raw bytes store (PLAN §26.5, 2026-11-10); the model is unchanged:

| Action | Code |
|---|---|
| the archiver: read, put, reference | `RawStore.compact/2` → `RawArchive.archive/3`: `Segments.stream/3` through one zstd context into `Blobs.put/3`, the count check, then `Blobs.pin/2` and `UPDATE … WHERE raw_status = 'segments'` in one transaction |
| the loser's checked delete | `Blobs.discard/2` |
| `DropPartition` with its guard | `RawStore.expire_partitions/1`: `RawStore.Expiry.partition_cutoff/2`, kept days by `RawArchive.holds_unarchived?/1` |
| the job not running for days | `RawStore.compact_due/2` is one job that snoozes itself; `conveyor_raw_archive_overdue_seconds` |

`compact_due/2` archives builds in batches and reads the raw-log objects a batch points
into once for all of its builds before any of them is archived. That is outside the
model and safe by an argument, not a check: a raw-log object is written once and never
changed, so bytes read ahead are the bytes a later read would return; every build then
goes through the same steps as alone (its own puts, its own reference transaction), and a
range that could not be read ahead is read by its build, which fails alone and is retried.
`raw_store_contract_test.exs` runs the model's chaos against the store's interface: two
archivers at once, a lost race, a build deleted meanwhile, a crash between the puts and
the reference (a trigger kills the reference transaction), a store outage, a mismatch.

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

The writer and `RawLog.put/2` already did the first two (`Writer.Store.put/1` runs before
the transaction, the row goes in before the bytes); the third is the change the model asked
for: the sweep's cutoff is bounded by `Partitions.oldest_day/0`, since an
object is registered when its batches commit and so never before their build's creation
day, a partition of day `d` only references objects registered on or after `d`.

Code ↔ model since the raw bytes store (PLAN §26.5, 2026-11-10); the model is unchanged:

| Action | Code |
|---|---|
| register the key, write the bytes | `RawStore.append/1` → `RawLog.put/2`: the row in its own transaction, then `c:Conveyor.Blobs.Adapter.put_object/3` (durable when it returns; the same key and bytes again on a retry) |
| commit the index rows, acknowledge | `Writer.Transaction.run/3` with the rows `RawStore.append/1` returned, then the session's ack |
| drop a partition | `RawStore.expire_partitions/1` (`RawStore.Expiry`, rule 1) |
| sweep | `RawStore.expire_objects/2` → `RawLog.sweep/2` with `RawStore.Expiry.object_cutoff/3` (rule 2: age, and the oldest live partition) |

The sweep now deletes in pages: the objects of a page in bulk
(`c:Conveyor.Blobs.Adapter.delete_objects/2`), then the registration rows of exactly the
keys the store reported deleted or absent. Per object the order is the model's (bytes,
then row), a crash between the two leaves rows whose objects are gone, which the next run
deletes as absent, and a key the store refuses keeps its row: `Registered` holds as
before. That the rules are what the model checked is tested at three clocks without
rewriting time in the database (`raw_store_contract_test.exs`: nothing goes on the last
day of retention; a sweep that runs before the partition drop deletes nothing however
late it is; the objects go only after the partition), and as a table of dates
(`raw_store/expiry_test.exs`).

Since 2026-11-09 (PLAN §26.3) a group's object is written once and every attempt of the
group commits against it: the retry after a failed commit, the group without its fenced or
expired batches, a half of it. In the model's terms the steps between "put" and "commit"
are one longer commit step, which the model already lets fail or be interrupted, so the
actions and both properties are unchanged. Two of its assumptions are touched and hold:
"a group commit takes seconds" is now enforced rather than assumed (a batch that has not
committed `INGEST_WRITER_DEADLINE_MS`, 20 s, after its submission leaves the group and is
never written, so a row never points at an object registered more than that before the
row's commit), and an object may now hold bytes no row points at (a batch that left the
group after the put). The model is per object, not per byte range: `Readable` asks that an
acknowledged batch's object exists, `Registered` that every object has a row for the
sweep, and unreferenced bytes inside a registered object affect neither; they are deleted
with the object.

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

## Writer commit pipeline (`Writer.tla`)

One shard, two invocations, stale submissions. The shard takes what was submitted as a
group (`Take`), stores the group's bytes as one object and attempts the group in one
transaction with the fence first (`Attempt`): fenced batches leave with the later batches
of their invocations and the rest is attempted again against the same object. A deadline
can pass at any point (`Expire`): the batch and its followers leave the group unwritten.
Tag counts are added after a commit the shard knows about. Chaos: a commit whose
acknowledgement is lost (the shard sees an error and attempts the group again, which now
fences).

| Property | Meaning |
|---|---|
| `Contiguous` | a committed batch's rows are exactly the row's advance (the fence) |
| `OneOutcome` | committed, failed and expired never overlap: in particular an expired batch is never reported committed, so never acknowledged |
| `Reported` | a batch reported committed is in the row |
| `Settled` | a batch in the row yet reported failed or expired can only come from a lost acknowledgement |
| `TagsExact` | the counted tags equal the committed batches |
| `OneObject` | a group stores at most one object however many attempts it takes |

| Config | Knobs | Result |
|---|---|---|
| `Writer_fixed.cfg` | no chaos, the object stored once per group | all hold (95,101 distinct states) |
| `Writer_lostack.cfg` | one lost acknowledgement | all but `TagsExact` hold (383,234 states): the retry fences, the client re-synchronises through dedup, nothing is lost, duplicated or wrongly acknowledged. This is why the session treats every failure as "may have committed" |
| `Writer_current.cfg` | the same with `TagsExact` | violated in 4 steps: the tag counts of the group whose acknowledgement was lost are never added. Accepted: facet counts are approximate by design and `Invocations.rebuild_tag_keys!/1` restores them |
| `Writer_reput.cfg` | a new object per attempt (the writer before 2026-11-09) | `OneObject` violated: a fenced group's second attempt stores a second object (the 153 PUTs/s of the 2026-11-06 resend storm, against a bound of 48) |

Code to model:

| Action | Code |
|---|---|
| `Submit` | `Writer.submit/2` (the batch, its submit time; the shard's pressure gauge) |
| `Take` | `Writer.Flush.decide/2` says `:flush` or the hold's timer fires; `Batch.units/1` merges each invocation's contiguous batches |
| `Expire` | the driver's deadline check before planning and before every attempt → `Writer.Policy.evict/3` with `:expired` |
| `Attempt`, the object | `Writer.Store.new/4` (layout fixed once) and `Store.put/1` (again only after a failed put, same key) |
| `Attempt`, the transaction | `Writer.Transaction.run/3`: fenced updates first, then the rows |
| `Attempt`, fenced | `Writer.Policy.record(p, {:fenced, keys})`: those units and the later units of their invocations get `:fenced`, the rest is attempted again |
| `Attempt`, lost acknowledgement | `Transaction.run/3` returns `{:error, :unavailable, _}` for a commit that did happen; the policy retries, the retry fences |
| reported committed, tags | `{:batch_committed, ref}` to each submitter; `TagCounter.add/1` after the commit |

Not in the model, in the policy's own tests (`writer/policy_test.exs`): the retry delays,
halving a group to isolate a row the database refuses, and the bound on attempts. They
choose which subset of the group an attempt holds and when; every attempt is still the
model's `Attempt` over batches in submission order, so the properties carry over. The
model's `Attempt` evicts the later batches of a fenced invocation as the policy does.

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
