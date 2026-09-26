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
(* row before the object. ObjectUnderLock — the deleter removes the object  *)
(* while it still holds the row lock, then drops the row, and the pin checks *)
(* the object exists while it holds the lock; the same content             *)
(* may be uploaded again at any moment (object written first, then the row  *)
(* upsert, which waits for a held lock). Found by Archive.tla: with the     *)
(* object deleted after the commit, a re-upload between the two lands its   *)
(* row, gets attached, and loses its object to the late delete.            *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS AtomicAttach, LockedDelete, ObjectUnderLock

VARIABLES
  row,        \* "none" | "ttl" | "pinned"
  object,     \* object bytes present
  refs,       \* references to the digest (0..2)
  expired,    \* the TTL has passed
  old,        \* older than the pruning grace period
  attach,     \* attacher step: "idle" | "checked" | "pinned" | "done"
  del,        \* deleter step: "idle" | "checked" | "locked" | "objgone"
  up          \* uploader step: "idle" | "written"

vars == <<row, object, refs, expired, old, attach, del, up>>

\* the deleter holds the row lock across steps (ObjectUnderLock only)
Locked == ObjectUnderLock /\ del \in {"locked", "objgone"}

Init ==
  /\ row = "none" /\ object = FALSE /\ refs = 0 /\ expired = FALSE /\ old = FALSE
  /\ attach = "idle" /\ del = "idle" /\ up = "idle"

\* Blobs.put: the object first (at any time, also while a delete is under way) ...
UploadObject ==
  /\ up = "idle"
  /\ object' = TRUE /\ up' = "written"
  /\ UNCHANGED <<row, refs, expired, old, attach, del>>

\* ... then the row upsert: a new row has a fresh TTL; an existing one keeps its pin
UploadRow ==
  /\ up = "written" /\ ~Locked
  /\ IF row = "none"
       THEN row' = "ttl" /\ expired' = FALSE /\ old' = FALSE
       ELSE UNCHANGED <<row, expired, old>>
  /\ up' = "idle"
  /\ UNCHANGED <<object, refs, attach, del>>

TimePasses ==
  /\ row # "none"
  /\ \/ (~expired /\ expired' = TRUE /\ old' = old)
     \/ (~old /\ old' = TRUE /\ expired' = expired)
  /\ UNCHANGED <<row, object, refs, attach, del, up>>

(* attach: exists? -> pin -> insert reference *)
AttachCheck ==
  /\ attach = "idle" /\ row # "none" /\ object
  /\ attach' = "checked"
  /\ UNCHANGED <<row, object, refs, expired, old, del, up>>

AttachPin ==
  /\ attach = "checked" /\ ~Locked
  /\ IF AtomicAttach
       THEN \* one transaction: the pin must hit the row, then the reference
            \* (ObjectUnderLock: the pin also checks the object while it holds the lock)
            IF row = "none" \/ (ObjectUnderLock /\ ~object)
              THEN attach' = "idle" /\ UNCHANGED <<row, refs>>   \* error: caller re-uploads
              ELSE attach' = "done" /\ row' = "pinned" /\ refs' = refs + 1
       ELSE \* pin ignores a missing row; the reference comes in a later step
            attach' = "pinned" /\ row' = (IF row = "none" THEN "none" ELSE "pinned") /\ refs' = refs
  /\ UNCHANGED <<object, expired, old, del, up>>

AttachInsert ==
  /\ attach = "pinned"
  /\ attach' = "done" /\ refs' = refs + 1
  /\ UNCHANGED <<row, object, expired, old, del, up>>

(* expiry or pruning: check -> delete object -> delete row *)
Eligible == row # "none" /\ ((row = "ttl" /\ expired) \/ (row = "pinned" /\ old /\ refs = 0))

DeleteCheck ==
  /\ del = "idle" /\ Eligible
  /\ IF LockedDelete
       THEN IF ObjectUnderLock
              THEN \* take the row lock and re-check; the object goes next, under it
                   /\ del' = "locked"
                   /\ UNCHANGED <<row, object>>
              ELSE \* under the row lock: re-check, drop the row; the object after commit
                   /\ del' = "objgone" /\ row' = "none"
                   /\ UNCHANGED object
       ELSE /\ del' = "checked"
            /\ UNCHANGED <<row, object>>
  /\ UNCHANGED <<refs, expired, old, attach, up>>

DeleteObject ==
  /\ del \in {"checked", "locked"}
  /\ del' = "objgone" /\ object' = FALSE
  /\ UNCHANGED <<row, refs, expired, old, attach, up>>

DeleteRow ==
  /\ del = "objgone"
  /\ del' = "idle"
  /\ IF LockedDelete /\ ~ObjectUnderLock
       THEN object' = FALSE /\ row' = row
       ELSE row' = "none" /\ object' = object
  /\ UNCHANGED <<refs, expired, old, attach, up>>

Next ==
  UploadObject \/ UploadRow \/ TimePasses \/ AttachCheck \/ AttachPin \/ AttachInsert
  \/ DeleteCheck \/ DeleteObject \/ DeleteRow

Spec == Init /\ [][Next]_vars

\* A reference must point at a blob whose row and object exist.
ReferencedIntact == refs > 0 => (row = "pinned" /\ object)

=============================================================================
