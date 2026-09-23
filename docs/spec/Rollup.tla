-------------------------------- MODULE Rollup --------------------------------
(* One project-hour: builds in it change (a late finish bumps updated_at); the job or a
   page reads the builds, computes the row and stamps it. A row is stale when its stamp is
   older than the newest build change. Property Fresh: whenever the row is considered
   fresh, it reflects every change. Knob StampBeforeCompute: the stamp is taken before the
   builds are read (fixed) or when the row is written (shipped). *)
EXTENDS Naturals
CONSTANTS StampBeforeCompute, MaxChanges
VARIABLES clock, buildChanged, rowStamp, rowSeen, computing, computeStart, computeSeen, changes
vars == <<clock, buildChanged, rowStamp, rowSeen, computing, computeStart, computeSeen, changes>>

Init == /\ clock = 2 /\ buildChanged = 0 /\ rowStamp = 0 /\ rowSeen = 0
        /\ computing = FALSE /\ computeStart = 0 /\ computeSeen = 0 /\ changes = 0

Tick == clock' = clock + 1 /\ clock < 8 /\ UNCHANGED <<buildChanged, rowStamp, rowSeen, computing, computeStart, computeSeen, changes>>

BuildChange == /\ changes < MaxChanges /\ changes' = changes + 1
               /\ buildChanged' = clock /\ UNCHANGED <<clock, rowStamp, rowSeen, computing, computeStart, computeSeen>>

Stale == rowStamp = 0 \/ rowStamp < buildChanged

StartCompute == /\ ~computing /\ Stale
                /\ computing' = TRUE /\ computeStart' = clock /\ computeSeen' = buildChanged
                /\ UNCHANGED <<clock, buildChanged, rowStamp, rowSeen, changes>>

FinishCompute == /\ computing
                 /\ computing' = FALSE /\ rowSeen' = computeSeen
                 \* the stamp sits a safety margin before the read, so a change in the same
                 \* instant (clock skew between nodes) still marks the row stale
                 /\ rowStamp' = IF StampBeforeCompute THEN computeStart - 1 ELSE clock
                 /\ UNCHANGED <<clock, buildChanged, computeStart, computeSeen, changes>>

Next == Tick \/ BuildChange \/ StartCompute \/ FinishCompute
Spec == Init /\ [][Next]_vars

\* A row that passes the staleness check reflects the latest change.
Fresh == (rowStamp # 0 /\ ~Stale) => rowSeen = buildChanged
=============================================================================
