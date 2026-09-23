--------------------------------- MODULE Oban ---------------------------------
(* One long job: it runs up to Timeout ticks; Lifeline rescues a job marked executing for
   longer than Rescue ticks, making it available again while the first run may still be
   going. Property OneRun: never two runs at once. Holds iff Timeout < Rescue. *)
EXTENDS Naturals
CONSTANTS Timeout, Rescue, Work
VARIABLES runs, elapsed, state, clock
vars == <<runs, elapsed, state, clock>>
Init == runs = 0 /\ elapsed = 0 /\ state = "available" /\ clock = 0
Start == state = "available" /\ state' = "executing" /\ runs' = runs + 1 /\ elapsed' = 0 /\ UNCHANGED clock
\* the timeout is enforced: time cannot pass a running job's limit without killing it
Tick == /\ clock' = clock + 1 /\ clock < 30 /\ UNCHANGED state /\ ~(runs > 0 /\ elapsed >= Timeout)
        /\ IF runs > 0 /\ state # "done" THEN elapsed' = elapsed + 1 ELSE elapsed' = elapsed
        /\ runs' = runs
Finish == runs > 0 /\ state = "executing" /\ elapsed >= Work /\ elapsed <= Timeout /\ state' = "done" /\ runs' = runs - 1 /\ UNCHANGED <<elapsed, clock>>
KillOnTimeout == runs > 0 /\ elapsed >= Timeout /\ state = "executing" /\ runs' = runs - 1 /\ state' = "available" /\ elapsed' = 0 /\ UNCHANGED clock
RescueJob == state = "executing" /\ elapsed >= Rescue /\ state' = "available" /\ UNCHANGED <<runs, elapsed, clock>>
Next == Start \/ Tick \/ Finish \/ KillOnTimeout \/ RescueJob
Spec == Init /\ [][Next]_vars
OneRun == runs <= 1
=============================================================================
