---
round: 232
verdict: FIXED
packages: [rpc_dart]
lens: RPC-15
bench: none — the instrument is `loop.py next` and its own output, run before and after with a control
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record. Approved 10 of 10
commit: yes
---

# Round 232 — the selector read an archive as a decision

## Target

`next` named **owner decision B-22** — a decision round 231 had just measured
unbuildable and handed back. The lead's status says `awaiting owner`; the
selector called it outstanding anyway.

Taken as the round's target rather than worked around, because this is RPC-15's
own subject — re-measure the loop's record, including what its machinery claims
— and because the selector points every remaining round of the backlog sweep.

## Hypothesis

`pending_decisions` decides on the `## Owner decision` SECTION being non-empty,
and that section is an archive rather than a state.

## Before

```
  loop.py next     Target: owner decision B-22
  loop.py status   Owner decisions not yet carried out: 1
                   Awaiting owner: 0
```

B-22's status is `awaiting owner` and its decision section opens with
"**Superseded — round 231 measured this to be unbuildable as written.** Kept
below because the reasoning still holds". The old text is deliberately retained,
and the selector read it as live.

**This is not new, and the cost is countable.** B-17 sat in the same state from
round 218, and rounds 219, 220, 221, 222 and 223 each opened by declining it —
five rounds whose first act was to overrule the selector by hand, each recording
"Not B-17: declined for the Nth time".

## Mechanism

The status is the state; the section is history. A lead keeps the superseded
text because the reasoning is worth reading — round 218's impossibility argument
is what stopped round 224 re-attempting it — so "non-empty section" can never
mean "live decision".

Round 230 widened the match to `awaiting owner` OR `decided by owner` to fix the
opposite bug (a decision losing its slot the moment it was written). That fix
was right and this one completes it: the slot belongs to `decided by owner`
alone, and `awaiting owner` means waiting, whatever the section still holds.

## After

```
  loop.py next     Target: lens RPC-01 — first by rank among the un-swept
  loop.py status   Owner decisions not yet carried out: 0
                   Awaiting owner: 1
                     B-22 — a consumer that binds and never drains ...
```

B-22 moved to the bucket that describes it.

## Canary

A verdict of "the target disappeared" is worthless without showing the mechanism
still works, so the control ran in the other direction: B-22's status set to
`decided by owner (round 999)`, nothing else touched.

```
  Target: owner decision B-22 — an owner decision not yet carried out
          comes before any lens
```

Picked up immediately. Reverted in place; `git diff` on the journal is empty.

## Gate

The config's gate covers the Dart workspace and this round changed neither Dart
nor the journal's schema. What was run is `loop.py lint` — 0 errors — plus the
before/after/control above, which is the gate for a change to the selector.

## Not fixed

**The same shape may live in `stop_condition`.** Its "the work awaits the owner"
branch tests `awaiting owner` directly, which is correct, but nothing checks the
inverse inconsistency: a lead marked `decided by owner` with an EMPTY decision
section is silently skipped rather than reported. `pending_decisions` skips it
with a comment; `lint` says nothing. Not fixed here because it has never
happened, and a check for a state nobody has reached is the coverage the config's
bar rules out.

**Round 230's widening and this narrowing are one fix arriving in two halves**,
and the second half took two rounds to notice because the first half made the
selector RIGHT in the common case. A tool that is wrong only for retired
decisions looks correct every time a decision is live.

## Links

Lead `../backlog/B-22-paused-consumer-never-repays-the-pool.md` — the lead that
exposed it; unchanged by this round beyond the control's revert.
Round `230-the-last-round.md` — where the other half of this fix shipped.
Round `231-the-two-candidates-are-one.md` — which produced the superseded
decision that made the bug visible.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [232]`.
