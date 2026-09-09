---
round: 231
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-01
bench: P-11 — reused
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record. Approved 10 of 10, and Q4 is what produced the finding
commit: yes
---

# Round 231 — the two candidates are one

## Target

B-22, the owner decision: split the credit paths so `_fcOnConsumed` and
`returnFlowCredit` credit the connection through the ledger while
`onFrameDiscarded` credits directly, after which `_fcForget` can repay
unconditionally.

## Hypothesis

The split removes the double-credit hazard, so the repay becomes safe and
CASE C goes from 4 calls to the full 12.

## Before

P-11 reproduced, unchanged from round 228:

```
  receiver drains                     12 calls, 3072 KiB, never wedged
  receiver never binds a listener     12 calls, 3072 KiB, never wedged
  receiver drains, per-stream OFF     12 calls, 3072 KiB, never wedged
  receiver BINDS and PAUSES            4 calls, 1024 KiB, wedged at call 4
```

## Mechanism

**The decision cannot be carried out as written, and the reason is a third
caller nobody counted.** `_fcOnConsumed` is reached from two places, not one:

```
  _fcMetered (462)          the consumer takes a message   OWED
  inbound dispatch (1325)   the else branch: no controller,
                            not deferred                   NEVER OWED
```

The `else` at 1325 is the credit-on-arrival path, and its own comment says what
it is for: "Nothing meters this one and no layer has claimed it, so it goes
straight into the pipeline's own buffers". That is **ordinary traffic** — a
stream whose receiver never called `getMessagesForStream`.

Those bytes were charged by the sender and were never entered in the ledger.
Routing `_fcOnConsumed` through `min(bytes, owed)` would credit them
`min(bytes, 0) = 0`, so the connection pool would only ever shrink. That is
worse than B-22: the wedge would stop needing a stuck consumer at all.

**The split therefore cannot key on the CALLER.** It has to key on whether a
debt was ever entered — and "no debt now" has two meanings, never-owed and
already-repaid, which an empty ledger cannot tell apart. Distinguishing them is
a per-stream mark.

> **Candidate 1 collapses into candidate 2.** "Split the credit paths" and "mark
> the stream repaid" are not alternatives; the first needs the second to be
> correct. The choice left is only where the mark lives.

## The bench is blind to this

Worth stating plainly, because it would have shipped: **P-11 cannot see the
regression the decision would have caused.** Its receiver calls
`getMessagesForStream` on every stream, in every arm including "never reads", so
a controller always exists and the 1325 branch is never taken. All four arms
would have stayed green while ordinary traffic lost its connection credit.

That is L-04 and L-05 again, one level up: the instrument answers the question
asked and is silent about the one that matters.

## After

n/a — nothing changed. `git diff` empty.

## Canary

n/a — no fix.

## Gate

No code changed. The gate proper is the one HEAD passed at the round-230 hotfix.

## Not fixed

B-22 goes back to the owner with the information the decision did not have, and
with the work the next round needs regardless of which shape is chosen:

1. **P-11 needs a fifth arm** that never calls `getMessagesForStream`, so the
   credit-on-arrival branch is exercised. Without it no fix here can be trusted,
   whichever candidate is taken.
2. **The mark's home is the real question.** Round 212 is the precedent for
   per-stream state outliving its stream, and `_fcOwedConn` is already capped by
   `_fcCanTrack` — a mark that keeps entries alive longer competes for that cap.

## Links

Lead `../backlog/B-22-paused-consumer-never-repays-the-pool.md` — reopened with
the third caller and the collapse of the two candidates.
Bench `../probes/P-11-connection-debt-with-a-paused-consumer.md` — its blind
spot recorded.
Round `228-the-branch-206-did-not-cover.md` — where B-22 was measured.
Round `218-generation-tagging-cannot-work.md` — the previous time a decision
turned out unimplementable as written, and the same discipline applied.
