-------------------------------- MODULE Writer --------------------------------
(* One writer shard (Conveyor.Ingest.Writer), two invocations. The shard takes what
   was submitted as a group and stores the group's raw bytes as one object (blob mode).
   An attempt is one transaction with the fence first: if any batch's row is not where
   the batch expects, nothing is written, the fenced batches leave with the later batches
   of their invocations, and the rest is attempted again against the same object. A batch
   past its deadline leaves before an attempt as expired. Tag counts are added after a
   commit the shard knows about, outside the transaction. Chaos: a commit succeeds but
   its acknowledgement is lost (LostAck); the shard sees an error and attempts the group
   again, which now fences.

   Properties:
     Contiguous - a committed batch's rows are exactly the row's advance (the fence)
     OneOutcome - committed, failed and expired are told apart: no batch gets two
     Reported   - a batch reported committed is committed (the ack is the commit)
     Settled    - a batch that is in the row and was reported failed or expired can only
                  come from a lost acknowledgement (the session treats every failure as
                  "may have committed" for this reason)
     TagsExact  - the counted tags equal the committed batches
     OneObject  - a group stores at most one object however many attempts it takes

   Knobs: MaxLostAcks (0: no chaos), StoreOnce (FALSE: a new object per attempt, the
   writer before 2026-11-09), MaxExpired (how many deadlines may pass). *)
EXTENDS Naturals, Sequences, FiniteSets
CONSTANTS Invs, MaxSeq, MaxLostAcks, MaxExpired, StoreOnce
VARIABLES dbLast, pending, group, stored, done, reported, failed, expired, tags,
          lostAcks, nextSeq, objects, groups
vars == <<dbLast, pending, group, stored, done, reported, failed, expired, tags,
          lostAcks, nextSeq, objects, groups>>

Init == /\ dbLast = [i \in Invs |-> 0] /\ pending = <<>> /\ group = <<>> /\ stored = FALSE
        /\ done = {} /\ reported = {} /\ failed = {} /\ expired = {} /\ tags = 0
        /\ lostAcks = 0 /\ nextSeq = [i \in Invs |-> 1] /\ objects = 0 /\ groups = 0

\* A worker submits its next contiguous batch; a stale worker (another node moved the
\* row) submits one that starts where its own view ended.
Submit(i, stale) ==
  /\ nextSeq[i] <= MaxSeq /\ Len(pending) < 3
  /\ LET first == IF stale THEN nextSeq[i] - 1 ELSE nextSeq[i] IN
     /\ first >= 1
     /\ pending' = Append(pending, [inv |-> i, first |-> first, last |-> nextSeq[i]])
     /\ nextSeq' = [nextSeq EXCEPT ![i] = @ + 1]
  /\ UNCHANGED <<dbLast, group, stored, done, reported, failed, expired, tags, lostAcks,
                 objects, groups>>

\* The hold elapsed (or the group is full): what waits becomes the group.
Take ==
  /\ group = <<>> /\ pending # <<>>
  /\ group' = pending /\ pending' = <<>> /\ stored' = FALSE /\ groups' = groups + 1
  /\ UNCHANGED <<dbLast, done, reported, failed, expired, tags, lostAcks, nextSeq, objects>>

Range(s) == {s[k] : k \in 1..Len(s)}
Valid(b, last) == last[b.inv] = b.first - 1

RECURSIVE Apply(_, _), Fenced(_, _, _), Without(_, _)

Apply(bs, last) == \* the fenced updates in order over a sequence of batches
  IF bs = <<>> THEN last ELSE Apply(Tail(bs), [last EXCEPT ![Head(bs).inv] = Head(bs).last])

\* The batches an attempt fences: those whose row is not where they expect, and every
\* later batch of an invocation that already has one (it could only fence too).
Fenced(bs, last, dead) ==
  IF bs = <<>> THEN {}
  ELSE LET b == Head(bs) IN
       IF b.inv \in dead \/ ~Valid(b, last)
         THEN {b} \cup Fenced(Tail(bs), last, dead \cup {b.inv})
         ELSE Fenced(Tail(bs), [last EXCEPT ![b.inv] = b.last], dead)

Without(bs, gone) ==
  IF bs = <<>> THEN <<>>
  ELSE IF Head(bs) \in gone THEN Without(Tail(bs), gone)
       ELSE <<Head(bs)>> \o Without(Tail(bs), gone)

\* A deadline passes: the batch leaves the group, never written by this shard, and the
\* later batches of its invocation with it.
Expire(k) ==
  /\ group # <<>> /\ k \in 1..Len(group) /\ Cardinality(expired) < MaxExpired
  /\ LET gone == {group[j] : j \in {j \in k..Len(group) : group[j].inv = group[k].inv}} IN
     /\ expired' = expired \cup gone
     /\ group' = Without(group, gone)
  /\ UNCHANGED <<dbLast, pending, stored, done, reported, failed, tags, lostAcks, nextSeq,
                 objects, groups>>

\* One attempt: the object first (once per group when StoreOnce), then the transaction.
Attempt ==
  /\ group # <<>>
  /\ stored' = TRUE
  /\ objects' = IF StoreOnce /\ stored THEN objects ELSE objects + 1
  /\ LET fenced == Fenced(group, dbLast, {}) IN
     IF fenced # {}
       THEN \* rolled back before a child row: the fenced leave, the rest goes again
            /\ failed' = failed \cup fenced /\ group' = Without(group, fenced)
            /\ UNCHANGED <<dbLast, done, reported, tags, lostAcks>>
       ELSE /\ dbLast' = Apply(group, dbLast) /\ done' = done \cup Range(group)
            /\ \/ \* the shard learns of the commit: outcomes and tag counts follow
                  /\ reported' = reported \cup Range(group) /\ tags' = tags + Len(group)
                  /\ group' = <<>> /\ UNCHANGED <<failed, lostAcks>>
               \/ \* committed, but the shard sees an error: it will attempt again
                  /\ lostAcks < MaxLostAcks /\ lostAcks' = lostAcks + 1
                  /\ UNCHANGED <<group, reported, failed, tags>>
  /\ UNCHANGED <<pending, expired, nextSeq, groups>>

Next == \/ \E i \in Invs, s \in BOOLEAN : Submit(i, s)
        \/ Take \/ Attempt \/ \E k \in 1..3 : Expire(k)
Spec == Init /\ [][Next]_vars

Contiguous == \A b \in done : dbLast[b.inv] >= b.last
OneOutcome == reported \cap failed = {} /\ reported \cap expired = {} /\ failed \cap expired = {}
Reported == reported \subseteq done
Settled == \A b \in done \cap (failed \cup expired) : lostAcks > 0
TagsExact == tags = Cardinality(done)
OneObject == objects <= groups
=============================================================================
