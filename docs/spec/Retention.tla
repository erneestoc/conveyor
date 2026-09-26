------------------------------- MODULE Retention -------------------------------
(* Retention deletes builds that started before the cutoff while a stream may still be
   live or resume: the worker's next commit is fenced (row gone), the client retries, the
   row is created again empty and the resent sequence is ahead of it, so the upload fails
   for good and a row without events stays behind. Knob SkipRecent: retention leaves out
   builds that changed within the idle window (a live stream always changes its row). *)
EXTENDS Naturals
CONSTANTS SkipRecent
VARIABLES row, committed, recent, worker, client, zombie
vars == <<row, committed, recent, worker, client, zombie>>
Init == row = "old" /\ committed = 3 /\ recent = TRUE /\ worker = "live" /\ client = "streaming" /\ zombie = FALSE
\* the stream keeps committing while live (each commit touches updated_at)
Commit == worker = "live" /\ row # "none" /\ committed' = committed + 1 /\ committed < 6 /\ recent' = TRUE /\ UNCHANGED <<row, worker, client, zombie>>
Quiet == recent /\ worker # "live" /\ recent' = FALSE /\ UNCHANGED <<row, committed, worker, client, zombie>>
Finish == worker = "live" /\ client = "streaming" /\ client' = "done" /\ worker' = "gone" /\ UNCHANGED <<row, committed, recent, zombie>>
Retention == row = "old" /\ (~SkipRecent \/ ~recent) /\ row' = "none" /\ UNCHANGED <<committed, recent, worker, client, zombie>>
\* the live worker's next commit is fenced: it exits and the stream fails
Fenced == worker = "live" /\ row = "none" /\ worker' = "gone" /\ client' = "retrying" /\ UNCHANGED <<row, committed, recent, zombie>>
\* the client resends from its last ack; a fresh row cannot accept a sequence ahead of it
Retry == client = "retrying" /\ row = "none" /\ row' = "fresh" /\ client' = "failed" /\ zombie' = TRUE /\ UNCHANGED <<committed, recent, worker>>
Next == Commit \/ Quiet \/ Finish \/ Retention \/ Fenced \/ Retry
Spec == Init /\ [][Next]_vars
NoZombie == ~zombie
=============================================================================
