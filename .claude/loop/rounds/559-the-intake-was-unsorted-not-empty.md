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

# Round 559 — the intake was unsorted, not empty

## Target

The ~47 unworked leads from the external audit of 2026-09-28, every one `round: — (not re-measured)`,
and the way rounds were choosing among them: **by title**.

Not a defect in the code. A defect in how the loop routes, which is what RPC-15 is for — and the
thing round 556 asked the owner about and did not get an answer to. Sorting the list needs no
decision; only what to DO with each class does.

**No code changed.**

## Hypothesis

From round 556, in the owner's words: *nobody but me uses the package* — so leads written for a
third-party audience are worth nothing, and that might be most of the intake.

## Before

Three leads from this intake, worked in three consecutive rounds:

```
B-154  every transport's pubspec floor unsatisfiable by any published core
       REAL, and worth nothing: a floor binds only a resolver outside this workspace
B-178  "a potential process kill on reconnect"
       severity REFUTED outright; what was left was a comment on the wrong call
B-184  a half-close overtaking a parked send
       REAL, severe, silent request truncation on the owner's own traffic
```

## Mechanism

**The hypothesis is half right, and the half it gets wrong is the expensive one.** B-184 is audit
intake and it was real, severe and about the owner's own data. So the list is not written for an
absent audience — it is *unsorted*, and mixing those three kinds in one flat list is what made title
order the selection rule.

One question grades all of them, and it is answerable from each lead's own `## Why it matters` line:

> Can this damage traffic through a transport as it is used here, with no third party needing to
> exist?

That is why this cost one pass rather than 47 rounds.

## After

`../checked/C-61-the-audit-intake-sorted-by-who-it-hurts.md`.

```
A  can damage the owner's own traffic                    23
B  needs a proxy, a foreign gRPC stack, or an
   external channel implementer to exist                  9
C  cost, prose, hygiene — no behaviour to damage          15
```

**Two of the A entries are the reason to grade by consequence rather than by subject.** B-198 reads
like an interop concern and is not — both ends are rpc_dart, so its caller refuses a name its own
responder routes, with nobody else involved. B-196 reads like infrastructure and costs every future
round its evidence.

**Two cautions are carried into the record rather than left to be rediscovered.** B-164 and B-194
describe themselves as hygiene "with one behavioural item" — the exact framing B-129 records as
having hidden a DoS surface — so they are to be split before they are worked. And B-145/B-150 move
from C to A on a single answer: whether the standalone HTTP/1.1 responder is used here at all. One
question, not two rounds.

## Canary

**None, and none is possible.** Nothing was switched off; the round sorted records.

What stands in for one is that the grading was derived from three rounds whose outcomes were
*already known and disagreed with each other*. A scheme that put B-154, B-178 and B-184 in the same
bucket would have been refuted on the spot — and the flat list did exactly that, which is the finding.

## Gate

Nothing outside `.claude/loop/` changed, so there is no behaviour for a gate to cover. `loop.py lint`
is the gate that applies here: 0 errors.

## Not fixed

**A grade is not evidence, and the record says so twice.** Every one of these is a reading of a
reading, and these same leads were graded wrong in BOTH directions three times already — B-129's
items 14, 15 and 16 are the recorded cases. The first thing any round still owes its lead is a
witness, and no status changed here.

**The B class is parked, not closed.** Those defects are real; their audience is currently empty. If
the packages ever get a second consumer the whole class re-grades, and B-191 goes first, because its
audience is an attacker rather than a collaborator and a public server has those regardless of users.

**The C class is not a queue.** It is a checklist for rounds that pass nearby — rule one makes a stale
comment the business of whatever round touches that file, which is what round 557 was.

**This does not shrink the open-lead count.** 74 before, 74 after. What it changes is which of the 74
a round should take, and that the answer no longer comes from reading titles.

## Links

Negative `../checked/C-61-the-audit-intake-sorted-by-who-it-hurts.md` — the table.
Round `556-no-published-core-satisfies-any-floor.md` — real, worth nothing.
Round `557-the-comment-named-a-zone-that-was-not-there.md` — severity refuted.
Round `558-the-half-close-overtook-the-payload.md` — real and severe, which is what kept the intake
from being written off.
Lead `../backlog/B-129-core-cleanup-items.md` — the recorded case of this intake's grading being wrong
in both directions.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [559]`.
