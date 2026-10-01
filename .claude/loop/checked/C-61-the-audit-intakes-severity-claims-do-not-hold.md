---
round: 559
commit: 1250b45e
paths: [.claude/loop/backlog/**]
scope: whether the external audit of 2026-09-28 can be trusted about the SEVERITY of what it filed
---

# C-61 — the audit intake's severity claims do not hold

## The claim being checked

The audit filed ~47 leads, each with a `## Why it matters` line stating its consequence. The question
is whether those lines can be trusted to decide what a round should take.

## They cannot, and the error goes in both directions

Three leads from this intake, worked in three consecutive rounds:

```
B-154  "a published transport resolving an older core fails to compile"
       TRUE, and worth nothing: a floor binds only a resolver outside this
       workspace, and the owner is the only consumer       (round 556)

B-178  "a potential process kill on reconnect"
       REFUTED. terminate() never errors at either state the method can be in;
       four arms silent against a positive control that escapes  (round 557)

B-184  "silent request truncation"
       TRUE and severe, on the owner's own traffic: a 64 B payload vanished and
       the send reported success                                 (round 558)
```

Three rounds, three different relationships between the filed severity and the measured one. The same
pattern then held for three more: **B-151** named the wrong method (`start()` is not the racy one;
`afterModulesStart` is), **B-192**'s crash claim rested on a comment about a different call, and
**B-182** was accurate.

So: **six measured, not one exactly as filed.** B-129 records the same thing from inside the intake —
its items 14, 15 and 16 were graded wrongly in both directions — and this is that finding at the
intake's scale.

## Control

The three calibration leads are each other's control: a reading that treats the audit's severity as
usable has to put all three in the same bucket, and they came out real-and-worthless, refuted, and
real-and-severe. Any rule that could not separate them is refuted by them.

The weaker half is stated too: this is a reading of readings. Nothing here was run, and the
calibration was fitted to outcomes already known rather than predicted.

## What this does and does not license

**Does**: treat a `## Why it matters` line as a hypothesis, never as a severity. The first thing a
round owes any lead from this intake is still a witness, and six for six it changed the answer.

**Does not**: license a standing classification of the backlog. Choosing a target is the round's own
judgement, recorded in its `## Target` — *"Weighing severity, reachability and what is worth finishing
is yours"* — and the severity bar lives in `config.md`. A table in `checked/` that ranks leads for
future rounds is neither of those things, and this record is not one.

Nothing was measured here and no lead's status changed.
