---
round: 218
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-03
bench: P-09 — reused
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered against the record and the bench; approved 9 of 10, Q6 n/a (nothing shipped, so no canary)
commit: no
---

# Round 218 — generation tagging cannot work, and the measurement says so

## Target

B-17, the owner decision and therefore the round's first target: generation-tag
the ids so the data loss goes regardless of the capability, AND warn at attach
when the transport lacks `IRpcStreamIdSequence`.

## Hypothesis

The proxy issues every id through `createStream()`, so it can record which
transport generation each belongs to and drop stream-scoped operations for ids
from a retired one. That was the plan, and it is capability-independent.

## Before

```
P-09, reused unchanged:

  factory returns          id before   id after   handlers ended
  the transport itself         1           3          0 -> 0     <- control
  a plain decorator            1           1          0 -> 1
```

## Mechanism

**The plan does not work, and cannot.** Implemented in full — a `_generation`
counter bumped at every `attach`, an `_idGeneration` ledger written in
`createStream`, and a staleness guard on all seven stream-scoped forwards — the
numbers did not move: still `0 -> 1`.

The reason is not a bug in the implementation. When the ids genuinely collide,
the new call is issued **the same integer**. So `_rememberId(1)` at the new
generation overwrites the dead call's entry, and `finishSending(1)` then looks
current. Refusing to overwrite instead makes the LIVE call's own half-close look
stale and drops it — which is precisely what the existing guard "a half-close on
the CURRENT transport is still sent" exists to catch.

> **An `int` does not carry enough to tell the dead caller's id 1 from the live
> caller's id 1.** Any scheme keyed on the id alone has this hole; the watermark
> works only because it prevents the collision from ever happening.

The warning half was also implemented and did NOT fire in the bench: the
callback is wired after the first attach, so the branch never ran with it set.
That is a fixable wiring order, but a diagnostic that has never been seen to
fire is not something to ship on the strength of reading it.

## After

n/a — everything was reverted. `git diff` is empty and `analyze` is green.

## Canary

n/a — nothing shipped. The control is P-09's first row, unchanged throughout.

## Gate

No code changed, so the gate is the one HEAD passed at round 212.

## Not fixed

The data loss stands, and B-17 goes back to the owner with information it did
not have when the decision was made. What WOULD work, and was not attempted
because it is much larger than the decision authorised:

**Id translation.** The proxy hands out ids from its OWN monotonic sequence and
keeps a map from proxy-id to (generation, inner-id), translating on every
stream-scoped call and on every inbound message's `streamId`. A retired proxy-id
has no live mapping, so it is droppable unambiguously, and the new call gets a
different proxy-id even when the inner transport reuses 1. Capability-
independent and correct — but it is a full translation layer over the transport
interface, including the inbound direction, which is a different size of job
from what was asked for.

The two options the owner already saw remain: refusing a transport without the
capability at attach (breaking, but airtight), or accepting the behaviour and
recording it as a negative.

## Links

Lead `../backlog/B-17-watermark-lost-through-a-decorator.md` — reopened with the
measured impossibility and the third option.
Bench `../probes/P-09-watermark-survives-a-decorator.md` — reused unchanged; it
is what showed the fix was not working rather than the record claiming it did.
Round `217-a-decorator-erases-the-stream-id-watermark.md` — the measurement.
