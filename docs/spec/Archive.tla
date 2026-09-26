-------------------------------- MODULE Archive --------------------------------
(***************************************************************************)
(* Raw-segments write-behind (HANDOFF §7 "NEXT", Conveyor.Workers.ArchiveRaw) *)
(* for one finished build: its events live in daily segment partitions      *)
(* (dropped by date, RETENTION_RAW_DAYS after the build's creation day);    *)
(* after RAW_ARCHIVE_AFTER_HOURS the archive job on any node reads the      *)
(* segments, puts one blob (object, then row), and records the reference    *)
(* with a conditional UPDATE (raw_status 'segments' -> 'archived'). The     *)
(* same content always hashes to the same digest, so two archivers and a    *)
(* re-run after a crash write the same blob. Orphan pruning deletes pinned  *)
(* blobs older than the grace period that nothing references; the archiver *)
(* that loses the conditional UPDATE deletes its blob through the same      *)
(* checked delete. Build retention deletes the build (and its reference).  *)
(*                                                                          *)
(* Property Stored: every event is in the segments or in the referenced     *)
(* blob at all times (until retention deletes the build).                   *)
(*                                                                          *)
(* Knobs:                                                                   *)
(*   DropGuard  - the partition drop skips a day that still holds a finished *)
(*                build that is not archived (otherwise it is date only).   *)
(*   AtomicRef  - the reference is recorded in one transaction that first   *)
(*                pins the blob row (row lock; fails when the row is gone). *)
(*   SafeReput  - a blob delete removes the object while it holds the row   *)
(*                lock, before dropping the row (otherwise after commit),   *)
(*                and Blobs.pin/2 checks the object exists under its lock.  *)
(*                                                                          *)
(* Chaos: archivers crash between any two steps, two nodes archive at once, *)
(* a deleter's transaction dies after the object delete (row stays), the    *)
(* archive job does not run for days (store outage), a late lifecycle       *)
(* finish touches the row after the archive, retention deletes the build.   *)
(* Assumption (unchanged from before the archive): a build finishes within *)
(* RETENTION_RAW_DAYS of its creation; abandoned builds are never archived *)
(* and their segments go with the partition, as before.                    *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS DropGuard, AtomicRef, SafeReput,
          R,        \* RETENTION_RAW_DAYS
          Delay     \* RAW_ARCHIVE_AFTER_HOURS in days

Nodes == {"n1", "n2"}
Deleters == {"prune"} \cup Nodes
MaxDay == R + 2

VARIABLES
  day,      \* days since the build's row was created (its partition day is 0)
  fin,      \* the stream finished with a final status
  finDay,   \* the day it finished
  recent,   \* the row changed within two idle windows
  deleted,  \* build retention deleted the row
  segs,     \* the build's segment rows exist (partition not dropped)
  ref,      \* invocations.raw_blob is set (raw_status = 'archived')
  row,      \* blob row: "none" | "pinned"
  obj,      \* blob object present in the store
  old,      \* blob row older than the pruning grace period
  pc,       \* archiver step per node
  seen,     \* what the archiver read from the segments
  del,      \* deleter step per deleter
  lock      \* holder of the blob row lock across steps: "free" or a deleter

vars == <<day, fin, finDay, recent, deleted, segs, ref, row, obj, old, pc, seen, del, lock>>

Init ==
  /\ day = 0 /\ fin = FALSE /\ finDay = 0 /\ recent = TRUE /\ deleted = FALSE
  /\ segs = TRUE /\ ref = FALSE /\ row = "none" /\ obj = FALSE /\ old = FALSE
  /\ pc = [n \in Nodes |-> "idle"] /\ seen = [n \in Nodes |-> FALSE]
  /\ del = [d \in Deleters |-> "idle"] /\ lock = "free"

(* --- time and the build ---------------------------------------------------- *)

Finish ==
  /\ ~fin /\ day < R
  /\ fin' = TRUE /\ finDay' = day /\ recent' = TRUE
  /\ UNCHANGED <<day, deleted, segs, ref, row, obj, old, pc, seen, del, lock>>

Tick ==
  /\ day < MaxDay /\ (day + 1 = R => fin)
  /\ day' = day + 1
  /\ UNCHANGED <<fin, finDay, recent, deleted, segs, ref, row, obj, old, pc, seen, del, lock>>

Quiet ==
  /\ recent /\ recent' = FALSE
  /\ UNCHANGED <<day, fin, finDay, deleted, segs, ref, row, obj, old, pc, seen, del, lock>>

\* the finish notification arriving late: a row update, never a segment row
LateLifecycle ==
  /\ fin /\ ~deleted /\ recent' = TRUE
  /\ UNCHANGED <<day, fin, finDay, deleted, segs, ref, row, obj, old, pc, seen, del, lock>>

BlobAges ==
  /\ row # "none" /\ ~old /\ old' = TRUE
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, row, obj, pc, seen, del, lock>>

Retention ==
  /\ fin /\ ~deleted /\ ~recent
  /\ deleted' = TRUE /\ ref' = FALSE
  /\ UNCHANGED <<day, fin, finDay, recent, segs, row, obj, old, pc, seen, del, lock>>

PartitionDrop ==
  /\ segs /\ day > R
  /\ DropGuard => (deleted \/ ref)
  /\ segs' = FALSE
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, ref, row, obj, old, pc, seen, del, lock>>

(* --- the archiver on node n ------------------------------------------------ *)

Read(n) ==
  /\ pc[n] = "idle" /\ fin /\ ~deleted /\ ~ref /\ ~recent /\ day >= finDay + Delay
  /\ pc' = [pc EXCEPT ![n] = "read"] /\ seen' = [seen EXCEPT ![n] = segs]
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, row, obj, old, del, lock>>

\* Blobs.put: the object first ...  (a read that found no segments stores nothing)
PutObject(n) ==
  /\ pc[n] = "read"
  /\ IF seen[n] THEN obj' = TRUE /\ pc' = [pc EXCEPT ![n] = "written"]
                ELSE pc' = [pc EXCEPT ![n] = "idle"] /\ obj' = obj
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, row, old, seen, del, lock>>

\* ... then the row (an upsert: waits for a held row lock; a new row is young)
PutRow(n) ==
  /\ pc[n] = "written" /\ lock = "free"
  /\ row' = "pinned" /\ old' = (row # "none" /\ old)
  /\ pc' = [pc EXCEPT ![n] = "put"]
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, obj, seen, del, lock>>

Reference(n) ==
  /\ pc[n] = "put" /\ lock = "free"
  /\ IF deleted \/ ref
       THEN \* 0 rows updated: another node archived it, or the build is gone
            /\ pc' = [pc EXCEPT ![n] = "idle"] /\ del' = [del EXCEPT ![n] = "checked"]
            /\ UNCHANGED ref
       ELSE IF AtomicRef /\ (row = "none" \/ (SafeReput /\ ~obj))
         THEN \* pin failed (or the object is missing): roll back, the next run retries
              /\ pc' = [pc EXCEPT ![n] = "idle"] /\ UNCHANGED <<ref, del>>
         ELSE /\ ref' = TRUE /\ pc' = [pc EXCEPT ![n] = "idle"] /\ UNCHANGED del
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, row, obj, old, seen, lock>>

Crash(n) ==
  /\ pc[n] \in {"read", "written", "put"}
  /\ pc' = [pc EXCEPT ![n] = "idle"]
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, row, obj, old, seen, del, lock>>

(* --- blob deletion: orphan pruning and an archiver's losing cleanup -------- *)

PruneCheck ==
  /\ del["prune"] = "idle" /\ row = "pinned" /\ old /\ ~ref
  /\ del' = [del EXCEPT !["prune"] = "checked"]
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, row, obj, old, pc, seen, lock>>

\* Blobs.delete_blob/2: lock the row, re-check pin and references, delete.
DeleteLocked(d) ==
  /\ del[d] = "checked" /\ lock = "free"
  /\ IF row = "pinned" /\ ~ref /\ (d = "prune" => old)
       THEN IF SafeReput
              THEN lock' = d /\ del' = [del EXCEPT ![d] = "objdel_locked"] /\ UNCHANGED row
              ELSE row' = "none" /\ del' = [del EXCEPT ![d] = "objdel"] /\ UNCHANGED lock
       ELSE del' = [del EXCEPT ![d] = "idle"] /\ UNCHANGED <<row, lock>>
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, obj, old, pc, seen>>

\* SafeReput: object deleted under the lock, then the row, then commit
DeleteObjectLocked(d) ==
  /\ del[d] = "objdel_locked"
  /\ obj' = FALSE /\ del' = [del EXCEPT ![d] = "droprow"]
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, row, old, pc, seen, lock>>

DropRowLocked(d) ==
  /\ del[d] = "droprow"
  /\ row' = "none" /\ lock' = "free" /\ del' = [del EXCEPT ![d] = "idle"]
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, obj, old, pc, seen>>

\* the deleter's transaction dies after the object delete: the row stays
DeleterCrash(d) ==
  /\ del[d] \in {"objdel_locked", "droprow"}
  /\ lock' = "free" /\ del' = [del EXCEPT ![d] = "idle"]
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, row, obj, old, pc, seen>>

\* today's order: the row went in the committed transaction, the object after it
DeleteObjectAfterCommit(d) ==
  /\ del[d] = "objdel"
  /\ obj' = FALSE /\ del' = [del EXCEPT ![d] = "idle"]
  /\ UNCHANGED <<day, fin, finDay, recent, deleted, segs, ref, row, old, pc, seen, lock>>

Next ==
  \/ Finish \/ Tick \/ Quiet \/ LateLifecycle \/ BlobAges \/ Retention \/ PartitionDrop
  \/ PruneCheck
  \/ \E n \in Nodes : Read(n) \/ PutObject(n) \/ PutRow(n) \/ Reference(n) \/ Crash(n)
  \/ \E d \in Deleters :
       DeleteLocked(d) \/ DeleteObjectLocked(d) \/ DropRowLocked(d) \/ DeleterCrash(d)
       \/ DeleteObjectAfterCommit(d)

Spec == Init /\ [][Next]_vars

Archived == ref /\ row = "pinned" /\ obj

\* every event is in the segments or in the blob the row references
Stored == deleted \/ segs \/ Archived

\* a reference always points at a blob whose row and object exist
ReferencedIntact == ref => (row = "pinned" /\ obj)

=============================================================================
