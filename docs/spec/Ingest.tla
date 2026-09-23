-------------------------------- MODULE Ingest --------------------------------
(***************************************************************************)
(* The Conveyor ingest protocol (lib/conveyor/ingest/worker.ex, writer.ex,  *)
(* ingest.ex) for one invocation: a Bazel-like client streams events 1..N   *)
(* plus the stream-finished marker N+1, resending from its last             *)
(* acknowledged event after every lost connection; each node runs at most   *)
(* one worker per invocation, which loads the row, absorbs events in order, *)
(* batches them and commits through a compare-and-set fence on the row's    *)
(* last committed sequence. Acknowledgements travel only over the           *)
(* connection that is open. Lifecycle notifications (attempt started and    *)
(* finished) may land on any node.                                          *)
(*                                                                          *)
(* Checked: an acknowledged event is durable (Durability), the row only     *)
(* ever grows contiguously (by construction of the fence), and with bounded *)
(* chaos every run finishes with the stream and the lifecycle recorded      *)
(* (Completes). Two knobs reproduce behaviours the AWS trial found and M10   *)
(* removed; DedupBelowCommitted switches between the dedup rule the code    *)
(* shipped with and the corrected one (see docs/spec/README.md).            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Nodes,                 \* e.g. {n1, n2}
  N,                     \* events per build; N+1 is the stream-finished marker
  MaxDrops,              \* connection losses the client suffers
  MaxDbFails,            \* commits that fail for a non-fence reason (DB hiccup)
  LifecycleStartsWorker, \* pre-M10: the attempt-started notification started a worker
  FinishRecordsWhenFenced, \* M10: a fenced finish is recorded directly
  DedupBelowCommitted,   \* TRUE: ack a resend at once only when it is committed
  None                   \* model value: the client has no open connection

ASSUME N \in Nat /\ N >= 1

Marker == N + 1
Seqs == 1..Marker
ASSUME None \notin Nodes

VARIABLES
  dbLast,       \* invocations.last_event_seq
  dbFinished,   \* stream_finished
  dbLifecycle,  \* lifecycle_finished
  wOn,          \* [Nodes -> BOOLEAN] a worker exists on the node
  wExp,         \* [Nodes -> Nat] next sequence the worker expects
  wCommitted,   \* [Nodes -> Nat] highest sequence the worker knows committed
  wBatch,       \* [Nodes -> SUBSET Seqs] absorbed, not yet handed to the writer
  wInflight,    \* [Nodes -> Seq(SUBSET Seqs)] batches at the writer, in order
  wOwed,        \* [Nodes -> SUBSET Seqs] sequences the open connection awaits acks for
  cConn,        \* node the client is connected to, or None
  cNext,        \* next sequence the client will send
  cAcked,       \* sequences the client has seen acknowledged
  cStarted,     \* attempt-started notification sent
  cFinishSent,  \* attempt-finished notification sent (Bazel sends it once)
  drops, dbFails

vars == <<dbLast, dbFinished, dbLifecycle, wOn, wExp, wCommitted, wBatch,
          wInflight, wOwed, cConn, cNext, cAcked, cStarted, cFinishSent, drops, dbFails>>

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : x >= y

Init ==
  /\ dbLast = 0 /\ dbFinished = FALSE /\ dbLifecycle = FALSE
  /\ wOn = [n \in Nodes |-> FALSE]
  /\ wExp = [n \in Nodes |-> 1]
  /\ wCommitted = [n \in Nodes |-> 0]
  /\ wBatch = [n \in Nodes |-> {}]
  /\ wInflight = [n \in Nodes |-> <<>>]
  /\ wOwed = [n \in Nodes |-> {}]
  /\ cConn = None /\ cNext = 1 /\ cAcked = {} /\ cStarted = FALSE /\ cFinishSent = FALSE
  /\ drops = 0 /\ dbFails = 0

(***************************************************************************)
(* Worker start: load_or_create! reads the row.                             *)
(***************************************************************************)
StartWorker(n) ==
  /\ wOn' = [wOn EXCEPT ![n] = TRUE]
  /\ wExp' = [wExp EXCEPT ![n] = dbLast + 1]
  /\ wCommitted' = [wCommitted EXCEPT ![n] = dbLast]
  /\ wBatch' = [wBatch EXCEPT ![n] = {}]
  /\ wInflight' = [wInflight EXCEPT ![n] = <<>>]
  /\ wOwed' = [wOwed EXCEPT ![n] = {}]

WorkerVarsUnchanged(n) ==
  UNCHANGED <<wOn, wExp, wCommitted, wBatch, wInflight, wOwed>>

(***************************************************************************)
(* Lifecycle attempt-started, on any node. Today it only touches the row;   *)
(* before M10 it started a worker there (the stray worker of the trial).    *)
(***************************************************************************)
LifecycleStarted(m) ==
  /\ ~cStarted
  /\ cStarted' = TRUE
  /\ IF LifecycleStartsWorker /\ ~wOn[m] THEN StartWorker(m) ELSE WorkerVarsUnchanged(m)
  /\ UNCHANGED <<dbLast, dbFinished, dbLifecycle, cConn, cNext, cAcked, cFinishSent, drops, dbFails>>

(***************************************************************************)
(* The client opens a connection to node n and resends from its last ack.   *)
(***************************************************************************)
Connect(n) ==
  /\ cConn = None
  /\ cStarted
  /\ ~(Seqs \subseteq cAcked)
  /\ cConn' = n
  /\ cNext' = IF cAcked = {} THEN 1 ELSE Max(cAcked) + 1
  /\ wOwed' = [wOwed EXCEPT ![n] = {}]
  /\ UNCHANGED <<dbLast, dbFinished, dbLifecycle, wOn, wExp, wCommitted, wBatch,
                 wInflight, cAcked, cStarted, cFinishSent, drops, dbFails>>

(***************************************************************************)
(* The client loses its connection; acknowledgements not yet read are lost. *)
(***************************************************************************)
Drop ==
  /\ cConn # None
  /\ drops < MaxDrops
  /\ drops' = drops + 1
  /\ cConn' = None
  /\ UNCHANGED <<dbLast, dbFinished, dbLifecycle, wOn, wExp, wCommitted, wBatch,
                 wInflight, wOwed, cNext, cAcked, cStarted, cFinishSent, dbFails>>

(***************************************************************************)
(* The client pushes its next event to the node it is connected to.         *)
(* Ingest.push: find or start the worker; Worker.handle_call({:push, ...}). *)
(***************************************************************************)
Absorb(n, s) ==
  /\ wBatch' = [wBatch EXCEPT ![n] = @ \cup {s}]
  /\ wExp' = [wExp EXCEPT ![n] = s + 1]
  /\ wOwed' = [wOwed EXCEPT ![n] = @ \cup {s}]
  /\ UNCHANGED <<wOn, wCommitted, wInflight>>

Push(n) ==
  /\ cConn = n
  /\ cNext \in Seqs
  /\ LET s == cNext
         on == wOn[n]
         exp == IF on THEN wExp[n] ELSE dbLast + 1
         committed == IF on THEN wCommitted[n] ELSE dbLast
         batch == IF on THEN wBatch[n] ELSE {}
         inflight == IF on THEN wInflight[n] ELSE <<>>
     IN
     /\ cNext' = s + 1
     /\ UNCHANGED <<dbLast, dbFinished, dbLifecycle, cStarted, cFinishSent, drops, dbFails>>
     /\ \/ \* already seen by this worker: the dedup rule
           /\ s < exp
           /\ IF s <= committed \/ ~DedupBelowCommitted
                THEN \* acknowledged at once
                     /\ cAcked' = cAcked \cup {s}
                     /\ cConn' = cConn
                     /\ IF on THEN WorkerVarsUnchanged(n)
                        ELSE StartWorker(n)
                ELSE \* absorbed but not committed: the ack follows the commit
                     /\ cAcked' = cAcked
                     /\ cConn' = cConn
                     /\ wOwed' = [wOwed EXCEPT ![n] = @ \cup {s}]
                     /\ UNCHANGED <<wOn, wExp, wCommitted, wBatch, wInflight>>
        \/ \* the expected sequence
           /\ s = exp
           /\ cAcked' = cAcked
           /\ cConn' = cConn
           /\ IF on
                THEN Absorb(n, s)
                ELSE /\ wOn' = [wOn EXCEPT ![n] = TRUE]
                     /\ wExp' = [wExp EXCEPT ![n] = s + 1]
                     /\ wCommitted' = [wCommitted EXCEPT ![n] = dbLast]
                     /\ wBatch' = [wBatch EXCEPT ![n] = {s}]
                     /\ wInflight' = [wInflight EXCEPT ![n] = <<>>]
                     /\ wOwed' = [wOwed EXCEPT ![n] = {s}]
        \/ \* ahead of the worker: takeover when nothing is buffered, else the
           \* stream fails with FAILED_PRECONDITION and the client reconnects
           /\ s > exp
           /\ cAcked' = cAcked
           /\ IF on /\ batch = {} /\ Len(inflight) = 0 /\ dbLast + 1 = s
                THEN /\ cConn' = cConn
                     /\ wOn' = wOn
                     /\ wExp' = [wExp EXCEPT ![n] = s + 1]
                     /\ wCommitted' = [wCommitted EXCEPT ![n] = dbLast]
                     /\ wBatch' = [wBatch EXCEPT ![n] = {s}]
                     /\ wInflight' = wInflight
                     /\ wOwed' = [wOwed EXCEPT ![n] = {s}]
                ELSE /\ cConn' = None
                     \* a failed takeover keeps the reloaded state (`{:error, fresh}`),
                     \* so the next attempt is judged against the row's sequence
                     /\ IF on /\ batch = {} /\ Len(inflight) = 0
                          THEN StartWorker(n)
                          ELSE IF on THEN WorkerVarsUnchanged(n) ELSE StartWorker(n)

(***************************************************************************)
(* The worker hands its batch to the writer.                                *)
(***************************************************************************)
Flush(n) ==
  /\ wOn[n] /\ wBatch[n] # {}
  /\ wInflight' = [wInflight EXCEPT ![n] = Append(@, wBatch[n])]
  /\ wBatch' = [wBatch EXCEPT ![n] = {}]
  /\ UNCHANGED <<dbLast, dbFinished, dbLifecycle, wOn, wExp, wCommitted, wOwed,
                 cConn, cNext, cAcked, cStarted, cFinishSent, drops, dbFails>>

(***************************************************************************)
(* The writer commits the head batch: UPDATE ... WHERE last_event_seq =     *)
(* first_seq - 1. Success acknowledges the batch to the open connection;    *)
(* a fence ends the worker and fails the stream it was serving.             *)
(***************************************************************************)
Commit(n) ==
  /\ wOn[n] /\ Len(wInflight[n]) > 0
  /\ LET b == Head(wInflight[n]) IN
     IF dbLast = Min(b) - 1
       THEN /\ dbLast' = Max(b)
            /\ dbFinished' = (dbFinished \/ Marker \in b)
            /\ wCommitted' = [wCommitted EXCEPT ![n] = Max(b)]
            /\ wInflight' = [wInflight EXCEPT ![n] = Tail(@)]
            /\ cAcked' = IF cConn = n THEN cAcked \cup (b \cap wOwed[n]) ELSE cAcked
            /\ wOwed' = [wOwed EXCEPT ![n] = @ \ b]
            /\ UNCHANGED <<wOn, wExp, wBatch, cConn>>
       ELSE \* fenced: another node moved the row
            /\ wOn' = [wOn EXCEPT ![n] = FALSE]
            /\ cConn' = IF cConn = n THEN None ELSE cConn
            /\ UNCHANGED <<dbLast, dbFinished, wExp, wCommitted, wBatch, wInflight,
                           wOwed, cAcked>>
  /\ UNCHANGED <<dbLifecycle, cNext, cStarted, cFinishSent, drops, dbFails>>

(***************************************************************************)
(* A commit fails for a reason that is not the fence (retries exhausted):   *)
(* the worker stops and the stream it was serving fails.                    *)
(***************************************************************************)
DbFail(n) ==
  /\ wOn[n] /\ Len(wInflight[n]) > 0
  /\ dbFails < MaxDbFails
  /\ dbFails' = dbFails + 1
  /\ wOn' = [wOn EXCEPT ![n] = FALSE]
  /\ cConn' = IF cConn = n THEN None ELSE cConn
  /\ UNCHANGED <<dbLast, dbFinished, dbLifecycle, wExp, wCommitted, wBatch, wInflight,
                 wOwed, cNext, cAcked, cStarted, cFinishSent, drops>>

(***************************************************************************)
(* Idle timeout or the linger after finalization: a quiet worker exits.     *)
(***************************************************************************)
Exit(n) ==
  /\ wOn[n] /\ wBatch[n] = {} /\ Len(wInflight[n]) = 0 /\ cConn # n
  /\ wOn' = [wOn EXCEPT ![n] = FALSE]
  /\ UNCHANGED <<dbLast, dbFinished, dbLifecycle, wExp, wCommitted, wBatch, wInflight,
                 wOwed, cConn, cNext, cAcked, cStarted, cFinishSent, drops, dbFails>>

(***************************************************************************)
(* Lifecycle attempt-finished after the stream is fully acknowledged; it    *)
(* may land on any node. A live worker commits it through the fence; when  *)
(* fenced (a stray worker) M10 records it directly instead of failing.      *)
(***************************************************************************)
LifecycleFinished(m) ==
  /\ Seqs \subseteq cAcked
  /\ ~cFinishSent
  /\ cFinishSent' = TRUE
  /\ IF wOn[m]
       THEN IF dbLast = wExp[m] - 1
              THEN dbLifecycle' = TRUE
              ELSE dbLifecycle' = FinishRecordsWhenFenced
       ELSE dbLifecycle' = TRUE
  /\ UNCHANGED <<dbLast, dbFinished, wOn, wExp, wCommitted, wBatch, wInflight, wOwed,
                 cConn, cNext, cAcked, cStarted, drops, dbFails>>

Next ==
  \/ \E m \in Nodes : LifecycleStarted(m)
  \/ \E n \in Nodes : Connect(n)
  \/ Drop
  \/ \E n \in Nodes : Push(n)
  \/ \E n \in Nodes : Flush(n)
  \/ \E n \in Nodes : Commit(n)
  \/ \E n \in Nodes : DbFail(n)
  \/ \E n \in Nodes : Exit(n)
  \/ \E m \in Nodes : LifecycleFinished(m)

\* Chaos is bounded by its counters; everything else is weakly fair.
Fairness ==
  /\ \A m \in Nodes : WF_vars(LifecycleStarted(m))
  /\ \A n \in Nodes : WF_vars(Connect(n))
  /\ \A n \in Nodes : WF_vars(Push(n))
  /\ \A n \in Nodes : WF_vars(Flush(n))
  /\ \A n \in Nodes : WF_vars(Commit(n))
  /\ \A m \in Nodes : WF_vars(LifecycleFinished(m))

Spec == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* Properties                                                               *)
(***************************************************************************)
TypeOK ==
  /\ dbLast \in 0..Marker
  /\ cNext \in 1..(Marker + 1)
  /\ cAcked \subseteq Seqs
  /\ \A n \in Nodes : wExp[n] \in 1..(Marker + 1)

\* Every acknowledged event is committed.
Durability == cAcked \subseteq 1..dbLast

\* No worker believes more is committed than the row holds.
KnownCommitted == \A n \in Nodes : wOn[n] => wCommitted[n] <= dbLast

\* The build completes: stream finished and lifecycle recorded.
Completes == <>(dbFinished /\ dbLifecycle /\ Seqs \subseteq cAcked)

=============================================================================
