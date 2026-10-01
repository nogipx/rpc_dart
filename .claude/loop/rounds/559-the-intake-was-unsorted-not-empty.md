---
round: 559
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: none — the subject is the loop's own data, and the evidence is three rounds of it against each other
budget: probes 0/5, canaries 0/5
commit: yes
release: none
---

# Round 559 — the intake's severity claims do not hold

## Target

The ~47 unworked leads from the external audit of 2026-09-28, every one `round: — (not re-measured)`,
and the question of whether their `## Why it matters` lines can be trusted to decide what a round
takes.

Not a defect in the code. A check on the loop's own data, which is what RPC-15 is for.

**No code changed.**

## Hypothesis

From round 556, in the owner's words: *nobody but me uses the package* — so leads written for a
third-party audience may be worth nothing, and that might be most of the intake.

## Before

Three leads from this intake, worked in three consecutive rounds:

```
B-154  "a published transport resolving an older core fails to compile"
       TRUE, and worth nothing: a floor binds only a resolver outside this
       workspace, and the owner is the only consumer            (round 556)

B-178  "a potential process kill on reconnect"
       REFUTED outright                                          (round 557)

B-184  "silent request truncation"
       TRUE and severe, on the owner's own traffic               (round 558)
```

## Mechanism

Nothing to change in the code. **The hypothesis is half right, and the half it gets wrong is the
expensive one**: B-184 is audit intake and it was real, severe and about the owner's own data. So the
problem is not that the leads are written for an absent audience — it is that their severity lines
cannot be trusted at all, and the error runs in both directions.

## After

`../checked/C-61-the-audit-intakes-severity-claims-do-not-hold.md`.

The finding is one sentence: **treat a `## Why it matters` line as a hypothesis owing a witness, never
as a severity.** B-129 records the same thing from inside one lead — its items 14, 15 and 16 were
graded wrongly both ways — and this is that at the intake's scale.

What it does NOT license is a standing ranking of the backlog. The skill is explicit that choosing a
target is the round's own judgement, recorded in its `## Target`: *"Weighing severity, reachability and
what is worth finishing is yours."* The severity bar lives in `config.md`. A table that orders leads
for future rounds is neither, and this round does not produce one.

## Canary

**None, and none is possible.** Nothing was switched off; the round checked records against outcomes.

What stands in for one is that the three leads were worked BEFORE this check and disagree with each
other: any reading that treats the audit's severity as usable has to put real-and-worthless, refuted
and real-and-severe in one bucket, and these three refuse to go.

The weaker half is stated too: this is a reading of readings, and the calibration was fitted to
outcomes already known rather than predicted.

## Gate

Nothing outside `.claude/loop/` changed. `loop.py lint` is the gate that applies: 0 errors.

## Not fixed

**This closes nothing and changes no status.** Every lead from the intake still owes a witness, and six
measured so far — B-154, B-178, B-184, B-151, B-192, B-182 — produced six different relationships
between the filed claim and the measured one.

**It does not shrink the open-lead count**, and it does not tell a later round which lead to take. That
remains the round's own call.

## Links

Negative `../checked/C-61-the-audit-intakes-severity-claims-do-not-hold.md` — the calibration.
Round `556-no-published-core-satisfies-any-floor.md` — true, worth nothing.
Round `557-the-comment-named-a-zone-that-was-not-there.md` — refuted.
Round `558-the-half-close-overtook-the-payload.md` — true and severe, which is what kept the intake from
being written off wholesale.
Lead `../backlog/B-129-core-cleanup-items.md` — the same error inside one lead.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [559]`.
