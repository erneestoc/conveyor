------------------------------ MODULE SpawnInputs ------------------------------
(***************************************************************************)
(* Deduplicated execution-log input lists (Conveyor.ExecLog): one list per  *)
(* (project, digest) in spawn_inputs, referenced by any number of spawn     *)
(* rows. A store writes the list (an upsert) and the spawns that reference  *)
(* it in one transaction; orphan pruning deletes lists older than a grace   *)
(* period that no spawn references; spawn retention and build retention    *)
(* delete spawns, which makes lists orphans.                               *)
(*                                                                          *)
(* Property Intact: a committed spawn always references a list that exists. *)
(*                                                                          *)
(* Knobs:                                                                   *)
(*   LockOnUpsert — the upsert takes the row lock when the list exists      *)
(*                  (INSERT ... ON CONFLICT DO UPDATE); without it (DO      *)
(*                  NOTHING) the store does not block a concurrent prune.    *)
(*   LockedRecheck — pruning locks the row and re-checks the references    *)
(*                   with a fresh snapshot before deleting; without it the  *)
(*                   delete trusts the candidate scan.                      *)
(* Chaos: a store crashes before its commit (its upsert rolls back), two    *)
(* stores of the same list at once, pruning at any moment, spawns deleted  *)
(* by retention at any moment.                                             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS LockOnUpsert, LockedRecheck

Stores == {"s1", "s2"}

VARIABLES
  list,     \* the list row exists (committed)
  old,      \* the row is older than the grace period
  refs,     \* committed spawn rows referencing it (0..2)
  st,       \* store step: "idle" | "upserted" | "done"
  holds,    \* store holds the row lock
  pr,       \* prune step: "idle" | "scanned" | "locked" | "keep" | "clear"
  plock     \* prune holds the row lock

vars == <<list, old, refs, st, holds, pr, plock>>

Init ==
  /\ list = FALSE /\ old = FALSE /\ refs = 0
  /\ st = [s \in Stores |-> "idle"] /\ holds = [s \in Stores |-> FALSE]
  /\ pr = "idle" /\ plock = FALSE

RowLocked == plock \/ \E s \in Stores : holds[s]

TimePasses ==
  /\ list /\ ~old /\ old' = TRUE
  /\ UNCHANGED <<list, refs, st, holds, pr, plock>>

(* --- a store: upsert the list, then the spawns, then commit ------------- *)

\* The upsert: a new row is written (uncommitted, but it exists for the lock's
\* purposes once committed); an existing row is locked only with LockOnUpsert.
Upsert(s) ==
  /\ st[s] = "idle" /\ ~RowLocked
  /\ st' = [st EXCEPT ![s] = "upserted"]
  /\ holds' = [holds EXCEPT ![s] = (list /\ LockOnUpsert) \/ ~list]
  /\ UNCHANGED <<list, old, refs, pr, plock>>

\* Commit: the list (new or refreshed, so young again) and one spawn become visible.
Commit(s) ==
  /\ st[s] = "upserted"
  /\ list' = TRUE /\ old' = FALSE /\ refs' = refs + 1
  /\ st' = [st EXCEPT ![s] = "done"] /\ holds' = [holds EXCEPT ![s] = FALSE]
  /\ UNCHANGED <<pr, plock>>

Crash(s) ==
  /\ st[s] = "upserted"
  /\ st' = [st EXCEPT ![s] = "idle"] /\ holds' = [holds EXCEPT ![s] = FALSE]
  /\ UNCHANGED <<list, old, refs, pr, plock>>

(* --- retention deletes spawns ------------------------------------------- *)

Retention ==
  /\ refs > 0 /\ refs' = refs - 1
  /\ UNCHANGED <<list, old, st, holds, pr, plock>>

(* --- orphan pruning: scan, lock, re-check, delete ------------------------ *)

Scan ==
  /\ pr = "idle" /\ list /\ old /\ refs = 0
  /\ pr' = "scanned"
  /\ UNCHANGED <<list, old, refs, st, holds, plock>>

Lock ==
  /\ pr = "scanned" /\ ~RowLocked
  /\ IF list THEN pr' = "locked" /\ plock' = TRUE
             ELSE pr' = "idle" /\ plock' = FALSE
  /\ UNCHANGED <<list, old, refs, st, holds>>

\* With LockedRecheck a fresh statement under the lock sees every committed reference;
\* without it the delete trusts the scan. The delete is a separate statement.
Recheck ==
  /\ pr = "locked"
  /\ pr' = (IF LockedRecheck /\ (refs > 0 \/ ~old) THEN "keep" ELSE "clear")
  /\ UNCHANGED <<list, old, refs, st, holds, plock>>

Delete ==
  /\ pr \in {"keep", "clear"}
  /\ list' = (IF pr = "clear" THEN FALSE ELSE list)
  /\ pr' = "idle" /\ plock' = FALSE
  /\ UNCHANGED <<old, refs, st, holds>>

Next ==
  \/ TimePasses \/ Retention \/ Scan \/ Lock \/ Recheck \/ Delete
  \/ \E s \in Stores : Upsert(s) \/ Commit(s) \/ Crash(s)

Spec == Init /\ [][Next]_vars

Intact == refs > 0 => list

=============================================================================
