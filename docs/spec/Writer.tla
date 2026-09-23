-------------------------------- MODULE Writer --------------------------------
(* One writer shard, two invocations: the flush commits every pending batch in one
   transaction ending with the fenced updates; if anything fences, the whole group rolls
   back and the batches are redone one by one. Tag counts are added after a successful
   commit, outside the transaction. Chaos: the commit succeeds but its acknowledgement is
   lost (LostAck), so the group is retried. Properties: a batch's rows land exactly once and
   in order (the fence, Contiguous), every submitted batch ends committed or failed
   (Settled); TagsExact says the counted tags equal the committed batches. *)
EXTENDS Naturals, Sequences, FiniteSets
CONSTANTS Invs, MaxSeq, MaxLostAcks
VARIABLES dbLast, pending, done, failed, tags, lostAcks, nextSeq
vars == <<dbLast, pending, done, failed, tags, lostAcks, nextSeq>>

Init == /\ dbLast = [i \in Invs |-> 0] /\ pending = <<>> /\ done = {} /\ failed = {}
        /\ tags = 0 /\ lostAcks = 0 /\ nextSeq = [i \in Invs |-> 1]

\* A worker submits its next contiguous batch; a stale worker (another node moved the
\* row) submits one that starts where its own view ended.
Submit(i, stale) ==
  /\ nextSeq[i] <= MaxSeq /\ Len(pending) < 3
  /\ LET first == IF stale THEN nextSeq[i] - 1 ELSE nextSeq[i] IN
     /\ first >= 1
     /\ pending' = Append(pending, [inv |-> i, first |-> first, last |-> nextSeq[i]])
     /\ nextSeq' = [nextSeq EXCEPT ![i] = @ + 1]
  /\ UNCHANGED <<dbLast, done, failed, tags, lostAcks>>

Valid(b, last) == last[b.inv] = b.first - 1

RECURSIVE Apply(_, _), AllValid(_, _)

Apply(bs, last) == \* fenced updates in order over a sequence of batches
  IF bs = <<>> THEN last ELSE Apply(Tail(bs), [last EXCEPT ![Head(bs).inv] = Head(bs).last])

AllValid(bs, last) ==
  IF bs = <<>> THEN TRUE
  ELSE Valid(Head(bs), last) /\ AllValid(Tail(bs), [last EXCEPT ![Head(bs).inv] = Head(bs).last])

Range(s) == {s[k] : k \in 1..Len(s)}

GroupCommit ==
  /\ pending # <<>> /\ AllValid(pending, dbLast)
  /\ dbLast' = Apply(pending, dbLast)
  /\ IF lostAcks < MaxLostAcks
       THEN \* committed, but the writer never learns: it retries the group, all fenced now,
            \* and redoes the batches one by one (all fenced): nothing counted, nothing lost
            /\ lostAcks' = lostAcks + 1 /\ failed' = failed \cup Range(pending) /\ tags' = tags
       ELSE /\ lostAcks' = lostAcks /\ failed' = failed /\ tags' = tags + Len(pending)
  /\ done' = done \cup Range(pending) /\ pending' = <<>>
  /\ UNCHANGED nextSeq

\* The group fenced: rolled back; batches are redone one by one.
Fallback ==
  /\ pending # <<>> /\ ~AllValid(pending, dbLast)
  /\ LET b == Head(pending) IN
     IF Valid(b, dbLast)
       THEN dbLast' = [dbLast EXCEPT ![b.inv] = b.last] /\ done' = done \cup {b} /\ tags' = tags + 1 /\ failed' = failed
       ELSE dbLast' = dbLast /\ done' = done /\ tags' = tags /\ failed' = failed \cup {b}
  /\ pending' = Tail(pending)
  /\ UNCHANGED <<lostAcks, nextSeq>>

Next == \/ \E i \in Invs, s \in BOOLEAN : Submit(i, s)
        \/ GroupCommit \/ Fallback
Spec == Init /\ [][Next]_vars

\* A committed batch's rows are exactly the row's advance: no gap, no double apply.
Contiguous == \A b \in done : dbLast[b.inv] >= b.last
Settled == \A b \in done \cap failed : lostAcks > 0   \* only a lost ack makes both true
TagsExact == tags = Cardinality(done)
=============================================================================
