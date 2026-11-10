-------------------------------- MODULE RawLog --------------------------------
(***************************************************************************)
(* The raw log in blob mode (PLAN §25 step 2; Conveyor.RawLog,              *)
(* Conveyor.Ingest.Writer.Store, Conveyor.Workers.RawLogSweep).             *)
(* A writer shard on each of two nodes takes the batches pending on it as   *)
(* one group, registers a fresh object key in raw_log_objects (its own tiny *)
(* transaction, stamped with the day), writes the group's bytes to that     *)
(* object, then commits the index rows (a byte range per batch) in the      *)
(* Postgres transaction; the acknowledgement follows that commit. A batch's *)
(* index row lives in the daily partition of its build's creation day,      *)
(* dropped by the hourly job once the day is older than RETENTION_RAW_DAYS  *)
(* (R). The daily sweep deletes the registered objects older than R + 1     *)
(* days, orphans of failed commits included, and never lists the store.     *)
(*                                                                          *)
(* Properties:                                                              *)
(*   Readable   - an acknowledged batch's bytes are readable from its index *)
(*                row's object until the row's partition is dropped.        *)
(*   Registered - every object in the store has a raw_log_objects row, so   *)
(*                the sweep will find it (no unreachable garbage).          *)
(*                                                                          *)
(* Knobs:                                                                   *)
(*   RegisterFirst    - the row goes in before the bytes (otherwise after). *)
(*   AckAfterCommit   - the ack follows the index commit (otherwise it is   *)
(*                      given as soon as the bytes are durable).            *)
(*   SweepByPartition - the sweep's cutoff is also bounded by the day of    *)
(*                      the oldest segment partition that still exists      *)
(*                      (otherwise it is R + 1 days of age alone).          *)
(*                                                                          *)
(* Chaos: a node dies between any two writer steps (its pending batches are *)
(* lost and resent by the client, which never saw an ack), a put fails, a   *)
(* commit fails after the put (an orphan object that the sweep collects),   *)
(* both nodes write at once (keys are per node and never collide), the      *)
(* clock crosses midnight while a batch waits in a writer, and the          *)
(* partition drop runs late or not at all (a stalled maintenance queue, or  *)
(* the archive's drop guard keeping the day: Archive.tla). Assumed: a group *)
(* commit takes seconds (client and transaction timeouts), so one in flight *)
(* crosses at most one midnight. Out of the model, as in Archive.tla: a     *)
(* build that outlives its partition (its rows would land in the default    *)
(* partition), the archive copying the bytes elsewhere, and a resend's      *)
(* dedup against committed rows (Ingest.tla).                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS RegisterFirst, AckAfterCommit, SweepByPartition,
          R,        \* RETENTION_RAW_DAYS
          NB,       \* batches the clients send
          MaxPuts   \* objects a writer may create (bounds the run)

Nodes == {"n1", "n2"}
Batches == 1..NB
MaxDay == R + 2
Days == 0..MaxDay
Never == MaxDay + 1
Keys == Nodes \X (1..MaxPuts)
NoKey == <<"none", 0>>
NoNode == "none"

VARIABLES
  day,     \* the UTC day; partitions, registration stamps and the sweep count in days
  bst,     \* batch: "unsent" (with the client) | "pending" (on a writer) | "committed" | "acked"
  bnode,   \* the node holding a pending batch
  bday,    \* the batch's partition day (its build's creation day), fixed at the first send
  bobj,    \* the object the batch's index row references (NoKey before the commit)
  segs,    \* the daily partition exists
  pc,      \* writer step per node: "idle" | "reg" (row, no bytes) | "bytes" (bytes, no row) | "written"
  wk,      \* the writer's current object key
  wd,      \* the day the writer's current group commit began
  wb,      \* the writer's current group of batches
  nk,      \* keys used per node
  oreg,    \* the object's raw_log_objects row exists
  oday,    \* the day the row was inserted
  obytes   \* the object's bytes are in the store

vars == <<day, bst, bnode, bday, bobj, segs, pc, wk, wd, wb, nk, oreg, oday, obytes>>

Init ==
  /\ day = 0
  /\ bst = [b \in Batches |-> "unsent"] /\ bnode = [b \in Batches |-> NoNode]
  /\ bday = [b \in Batches |-> Never] /\ bobj = [b \in Batches |-> NoKey]
  /\ segs = [p \in Days |-> TRUE]
  /\ pc = [n \in Nodes |-> "idle"] /\ wk = [n \in Nodes |-> NoKey] /\ wd = [n \in Nodes |-> 0]
  /\ wb = [n \in Nodes |-> {}] /\ nk = [n \in Nodes |-> 0]
  /\ oreg = [k \in Keys |-> FALSE] /\ oday = [k \in Keys |-> 0] /\ obytes = [k \in Keys |-> FALSE]

\* the day of the oldest partition that still exists (past every day when none does)
Oldest == IF \E p \in Days : segs[p]
            THEN CHOOSE p \in Days : segs[p] /\ \A q \in Days : segs[q] => p <= q
            ELSE Never

Pending(n) == {b \in Batches : bst[b] = "pending" /\ bnode[b] = n}

(* --- time and the partitions ----------------------------------------------- *)

\* a group commit takes seconds (client and transaction timeouts), so one in flight
\* crosses at most one midnight
Tick ==
  /\ day < MaxDay /\ \A n \in Nodes : pc[n] = "idle" \/ wd[n] = day
  /\ day' = day + 1
  /\ UNCHANGED <<bst, bnode, bday, bobj, segs, pc, wk, wd, wb, nk, oreg, oday, obytes>>

\* PartitionMaintenance (hourly): drop the days older than R; it may run late
PartitionDrop(p) ==
  /\ segs[p] /\ day > p + R
  /\ segs' = [segs EXCEPT ![p] = FALSE]
  /\ UNCHANGED <<day, bst, bnode, bday, bobj, pc, wk, wd, wb, nk, oreg, oday, obytes>>

(* --- the client ------------------------------------------------------------ *)

\* a new batch, or the resend of one that was never acknowledged, to any node
Send(b, n) ==
  /\ bst[b] = "unsent"
  /\ LET p == IF bday[b] = Never THEN day ELSE bday[b] IN
       /\ segs[p]
       /\ bday' = [bday EXCEPT ![b] = p]
  /\ bst' = [bst EXCEPT ![b] = "pending"] /\ bnode' = [bnode EXCEPT ![b] = n]
  /\ UNCHANGED <<day, bobj, segs, pc, wk, wd, wb, nk, oreg, oday, obytes>>

\* Ingest.Worker: the ack follows the index commit
Ack(b) ==
  /\ bst[b] = "committed" /\ bst' = [bst EXCEPT ![b] = "acked"]
  /\ UNCHANGED <<day, bnode, bday, bobj, segs, pc, wk, wd, wb, nk, oreg, oday, obytes>>

\* the tempting shortcut: acknowledge once the bytes are durable, before the commit
AckEarly(b) ==
  /\ ~AckAfterCommit
  /\ bst[b] = "pending" /\ pc[bnode[b]] = "written" /\ b \in wb[bnode[b]]
  /\ bst' = [bst EXCEPT ![b] = "acked"]
  /\ UNCHANGED <<day, bnode, bday, bobj, segs, pc, wk, wd, wb, nk, oreg, oday, obytes>>

(* --- the writer shard on node n ------------------------------------------- *)

\* the group commit begins: a fresh key; RawLog.put registers it first ...
Start(n) ==
  /\ pc[n] = "idle" /\ Pending(n) # {} /\ nk[n] < MaxPuts
  /\ LET k == <<n, nk[n] + 1>> IN
       /\ nk' = [nk EXCEPT ![n] = nk[n] + 1] /\ wk' = [wk EXCEPT ![n] = k]
       /\ wd' = [wd EXCEPT ![n] = day]
       /\ wb' = [wb EXCEPT ![n] = Pending(n)]
       /\ IF RegisterFirst
            THEN /\ oreg' = [oreg EXCEPT ![k] = TRUE] /\ oday' = [oday EXCEPT ![k] = day]
                 /\ pc' = [pc EXCEPT ![n] = "reg"] /\ UNCHANGED obytes
            ELSE /\ obytes' = [obytes EXCEPT ![k] = TRUE]
                 /\ pc' = [pc EXCEPT ![n] = "bytes"] /\ UNCHANGED <<oreg, oday>>
  /\ UNCHANGED <<day, bst, bnode, bday, bobj, segs>>

\* ... then writes the bytes
Put(n) ==
  /\ pc[n] = "reg"
  /\ obytes' = [obytes EXCEPT ![wk[n]] = TRUE] /\ pc' = [pc EXCEPT ![n] = "written"]
  /\ UNCHANGED <<day, bst, bnode, bday, bobj, segs, wk, wd, wb, nk, oreg, oday>>

\* the put fails: the writer raises, the batches fail their workers, the clients
\* resend; the row stays as an orphan without bytes until the sweep
PutFail(n) ==
  /\ pc[n] = "reg"
  /\ pc' = [pc EXCEPT ![n] = "idle"] /\ wb' = [wb EXCEPT ![n] = {}]
  /\ bst' = [b \in Batches |-> IF b \in wb[n] /\ bst[b] = "pending" THEN "unsent" ELSE bst[b]]
  /\ UNCHANGED <<day, bnode, bday, bobj, segs, wk, wd, nk, oreg, oday, obytes>>

\* ~RegisterFirst: the row after the bytes
Register(n) ==
  /\ pc[n] = "bytes"
  /\ oreg' = [oreg EXCEPT ![wk[n]] = TRUE] /\ oday' = [oday EXCEPT ![wk[n]] = day]
  /\ pc' = [pc EXCEPT ![n] = "written"]
  /\ UNCHANGED <<day, bst, bnode, bday, bobj, segs, wk, wd, wb, nk, obytes>>

\* the index rows commit, each into its build's partition
Commit(n) ==
  /\ pc[n] = "written" /\ \A b \in wb[n] : segs[bday[b]]
  /\ bobj' = [b \in Batches |-> IF b \in wb[n] THEN wk[n] ELSE bobj[b]]
  /\ bst' = [b \in Batches |-> IF b \in wb[n] /\ bst[b] = "pending" THEN "committed" ELSE bst[b]]
  /\ pc' = [pc EXCEPT ![n] = "idle"] /\ wb' = [wb EXCEPT ![n] = {}]
  /\ UNCHANGED <<day, bnode, bday, segs, wk, wd, nk, oreg, oday, obytes>>

\* the transaction fails (or fences) after the put: an orphan object with a row and
\* bytes that nothing references; the batches are resent
CommitFail(n) ==
  /\ pc[n] = "written"
  /\ pc' = [pc EXCEPT ![n] = "idle"] /\ wb' = [wb EXCEPT ![n] = {}]
  /\ bst' = [b \in Batches |-> IF b \in wb[n] /\ bst[b] = "pending" THEN "unsent" ELSE bst[b]]
  /\ UNCHANGED <<day, bnode, bday, bobj, segs, wk, wd, nk, oreg, oday, obytes>>

\* the node dies mid-flight: every batch pending on it goes back to its client
Crash(n) ==
  /\ pc[n] # "idle"
  /\ pc' = [pc EXCEPT ![n] = "idle"] /\ wb' = [wb EXCEPT ![n] = {}]
  /\ bst' = [b \in Batches |-> IF bnode[b] = n /\ bst[b] = "pending" THEN "unsent" ELSE bst[b]]
  /\ UNCHANGED <<day, bnode, bday, bobj, segs, wk, wd, nk, oreg, oday, obytes>>

(* --- the daily sweep ------------------------------------------------------- *)

\* RawLogSweep: delete the objects registered more than R + 1 days ago (the bytes,
\* then the row; a missing object counts as deleted)
Sweep(k) ==
  /\ oreg[k] /\ day >= oday[k] + R + 1
  /\ SweepByPartition => oday[k] < Oldest
  /\ obytes' = [obytes EXCEPT ![k] = FALSE] /\ oreg' = [oreg EXCEPT ![k] = FALSE]
  /\ UNCHANGED <<day, bst, bnode, bday, bobj, segs, pc, wk, wd, wb, nk, oday>>

Next ==
  \/ Tick
  \/ \E p \in Days : PartitionDrop(p)
  \/ \E b \in Batches : Ack(b) \/ AckEarly(b) \/ \E n \in Nodes : Send(b, n)
  \/ \E n \in Nodes :
       Start(n) \/ Put(n) \/ PutFail(n) \/ Register(n) \/ Commit(n) \/ CommitFail(n) \/ Crash(n)
  \/ \E k \in Keys : Sweep(k)

Spec == Init /\ [][Next]_vars

\* an acknowledged batch's bytes are readable until its partition is dropped
Readable ==
  \A b \in Batches :
    (bst[b] = "acked" /\ segs[bday[b]]) => (bobj[b] # NoKey /\ obytes[bobj[b]])

\* every object in the store is registered, so the sweep will reach it
Registered == \A k \in Keys : obytes[k] => oreg[k]

=============================================================================
