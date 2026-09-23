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

Run:

```sh
docs/spec/check.sh            # all three configurations
docs/spec/check.sh fixed      # one
```

TLC needs Java and `tla2tools.jar` (`TLA_TOOLS=/path/to/tla2tools.jar`, default
`~/tla/tla2tools.jar` from https://github.com/tlaplus/tlaplus/releases). Re-run the model
when the worker or writer protocol changes; keep the spec's actions aligned with
`worker.ex` (`handle_call({:push, …})`, `takeover/2`, `handle_info({:batch_committed…})`),
`writer.ex` (`fenced_update!/3`) and `ingest.ex` (`lifecycle/2`).

Not modelled: several invocations, the writer's group commit across invocations (the
fence is per row), backpressure, the log cap, retries inside the writer (a `DbFail` is the
exhausted retry), and the contents of events.
