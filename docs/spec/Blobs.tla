--------------------------------- MODULE Blobs ---------------------------------
(***************************************************************************)
(* Blob lifecycle for one digest of one project (lib/conveyor/blobs.ex,     *)
(* artifacts.ex): an upload stores the object and a row with a TTL; an     *)
(* attach (profile fetch, artifact upload) checks the blob exists, pins the *)
(* row (clears the TTL) and inserts a reference; expiry deletes blobs whose *)
(* TTL passed; orphan pruning deletes pinned blobs older than the grace     *)
(* period that nothing references. Property: a reference always points at   *)
(* a blob whose row and object exist (ReferencedIntact).                    *)
(*                                                                          *)
(* Knobs: AtomicAttach — the pin and the reference are one transaction and  *)
(* the pin fails when the row is gone; LockedDelete — expiry and pruning    *)
(* re-check the pin and the references under the row lock and delete the    *)
(* row before the object.                                                   *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS AtomicAttach, LockedDelete

VARIABLES
  row,        \* "none" | "ttl" | "pinned"
  object,     \* object bytes present
  refs,       \* references to the digest (0..2)
  expired,    \* the TTL has passed
  old,        \* older than the pruning grace period
  attach,     \* attacher step: "idle" | "checked" | "pinned" | "done"
  del         \* deleter step: "idle" | "checked" | "objgone"

vars == <<row, object, refs, expired, old, attach, del>>

Init ==
  /\ row = "none" /\ object = FALSE /\ refs = 0 /\ expired = FALSE /\ old = FALSE
  /\ attach = "idle" /\ del = "idle"

Upload ==
  /\ row = "none" /\ attach = "idle" /\ del = "idle"
  /\ row' = "ttl" /\ object' = TRUE /\ expired' = FALSE /\ old' = FALSE
  /\ UNCHANGED <<refs, attach, del>>

TimePasses ==
  /\ row # "none"
  /\ \/ (~expired /\ expired' = TRUE /\ old' = old)
     \/ (~old /\ old' = TRUE /\ expired' = expired)
  /\ UNCHANGED <<row, object, refs, attach, del>>

(* attach: exists? -> pin -> insert reference *)
AttachCheck ==
  /\ attach = "idle" /\ row # "none" /\ object
  /\ attach' = "checked"
  /\ UNCHANGED <<row, object, refs, expired, old, del>>

AttachPin ==
  /\ attach = "checked"
  /\ IF AtomicAttach
       THEN \* one transaction: the pin must hit the row, then the reference
            IF row = "none"
              THEN attach' = "idle" /\ UNCHANGED <<row, refs>>   \* error: caller re-uploads
              ELSE attach' = "done" /\ row' = "pinned" /\ refs' = refs + 1
       ELSE \* pin ignores a missing row; the reference comes in a later step
            attach' = "pinned" /\ row' = (IF row = "none" THEN "none" ELSE "pinned") /\ refs' = refs
  /\ UNCHANGED <<object, expired, old, del>>

AttachInsert ==
  /\ attach = "pinned"
  /\ attach' = "done" /\ refs' = refs + 1
  /\ UNCHANGED <<row, object, expired, old, del>>

(* expiry or pruning: check -> delete object -> delete row *)
Eligible == row # "none" /\ ((row = "ttl" /\ expired) \/ (row = "pinned" /\ old /\ refs = 0))

DeleteCheck ==
  /\ del = "idle" /\ Eligible
  /\ IF LockedDelete
       THEN \* under the row lock: re-check, drop the row, then the object
            /\ del' = "objgone" /\ row' = "none"
            /\ UNCHANGED object
       ELSE /\ del' = "checked"
            /\ UNCHANGED <<row, object>>
  /\ UNCHANGED <<refs, expired, old, attach>>

DeleteObject ==
  /\ del = "checked"
  /\ del' = "objgone" /\ object' = FALSE
  /\ UNCHANGED <<row, refs, expired, old, attach>>

DeleteRow ==
  /\ del = "objgone"
  /\ del' = "idle"
  /\ IF LockedDelete THEN object' = FALSE /\ row' = row ELSE row' = "none" /\ object' = object
  /\ UNCHANGED <<refs, expired, old, attach>>

Next ==
  Upload \/ TimePasses \/ AttachCheck \/ AttachPin \/ AttachInsert
  \/ DeleteCheck \/ DeleteObject \/ DeleteRow

Spec == Init /\ [][Next]_vars

\* A reference must point at a blob whose row and object exist.
ReferencedIntact == refs > 0 => (row = "pinned" /\ object)

=============================================================================
