------------------------------ MODULE ActionKeys ------------------------------
(* One action key of one scope (PLAN 27). Executions of the key, each with a start and a
   finish taken from clocks nobody controls, sit in logs that parsers store in any order
   and at the same time. A parser locks the key's row, merges its execution (the row
   keeps the smallest (finish, start, id)) and commits; the builds whose executions were
   already stored are touched when the row changed. A rolled hour holds the class of an
   execution as it was computed from the row at that moment; it is stale until rolled
   again.

   Knobs:
     Derive  TRUE  the class is computed from the row when an hour is rolled (shipped)
             FALSE the class is fixed when the execution is parsed (classify on arrival)
     Touch   TRUE  a merge that changes the row marks the other stored executions stale
             FALSE only the parsed build is marked (the gap this step closes)

   Properties:
     Exact   when every log is stored and nothing is stale, the row is the earliest
             finisher and every execution has the class of the definition, so wasted
             time is the total minus the earliest finisher's.
     Fresh   an execution that is not stale shows the class its row gives it now. *)
EXTENDS Naturals, FiniteSets
CONSTANTS Execs, MaxTime, Parsers, Derive, Touch
VARIABLES start, finish, pending, row, lock, held, parsed, shown, stale
vars == <<start, finish, pending, row, lock, held, parsed, shown, stale>>

None == 0
Less(a, b) == \/ finish[a] < finish[b]
              \/ finish[a] = finish[b] /\ start[a] < start[b]
              \/ finish[a] = finish[b] /\ start[a] = start[b] /\ a < b

Class(e, first) == IF first = None \/ first = e THEN "first"
                   ELSE IF start[e] < finish[first] THEN "racing" ELSE "sequential"

Init == /\ start \in [Execs -> 1..MaxTime] /\ finish \in [Execs -> 1..MaxTime]
        /\ \A e \in Execs : start[e] < finish[e]
        /\ pending = Execs /\ row = None /\ lock = None
        /\ held = [p \in Parsers |-> None]
        /\ parsed = [e \in Execs |-> "none"] /\ shown = [e \in Execs |-> "none"]
        /\ stale = [e \in Execs |-> FALSE]

Stored == {e \in Execs : parsed[e] # "none"}

\* A parser takes a log and waits for the row's lock (rows are locked in key order).
Take(p, e) == /\ held[p] = None /\ e \in pending /\ lock = None
              /\ held' = [held EXCEPT ![p] = e] /\ lock' = p /\ pending' = pending \ {e}
              /\ UNCHANGED <<start, finish, row, parsed, shown, stale>>

\* The upsert, the touch and the commit: one transaction under the row's lock.
Merge(p) == /\ lock = p
            /\ LET e == held[p]
                   new == IF row = None \/ Less(e, row) THEN e ELSE row
                   changed == new # row /\ row # None
               IN /\ row' = new
                  /\ parsed' = [parsed EXCEPT ![e] = Class(e, new)]
                  /\ stale' = [x \in Execs |->
                                 IF x = e THEN TRUE
                                 ELSE IF Touch /\ changed /\ x \in Stored THEN TRUE
                                 ELSE stale[x]]
            /\ lock' = None /\ held' = [held EXCEPT ![p] = None]
            /\ UNCHANGED <<start, finish, pending, shown>>

\* An hour is rolled: the class shown is read from the row, or is the one fixed at parse.
Roll(e) == /\ e \in Stored /\ stale[e]
           /\ shown' = [shown EXCEPT ![e] = IF Derive THEN Class(e, row) ELSE parsed[e]]
           /\ stale' = [stale EXCEPT ![e] = FALSE]
           /\ UNCHANGED <<start, finish, pending, row, lock, held, parsed>>

Next == \/ \E p \in Parsers, e \in Execs : Take(p, e)
        \/ \E p \in Parsers : Merge(p)
        \/ \E e \in Execs : Roll(e)
Spec == Init /\ [][Next]_vars

Earliest == CHOOSE e \in Execs : \A x \in Execs \ {e} : Less(e, x)
Quiet == pending = {} /\ lock = None /\ \A e \in Execs : ~stale[e]

Exact == Quiet => /\ row = Earliest
                  /\ \A e \in Execs : shown[e] = Class(e, Earliest)
                  /\ Cardinality({e \in Execs : shown[e] = "first"}) = 1
Fresh == \A e \in Stored : (~stale[e] /\ shown[e] # "none" /\ lock = None) => shown[e] = Class(e, row)
=============================================================================
