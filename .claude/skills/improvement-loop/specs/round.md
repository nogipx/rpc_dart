# Schema: the round file

> [Schemas](SPECS.md) · written at the **Gate** step, per
> [methods/reporting.md](../methods/reporting.md) · checked by `loop.py lint`

Path: `.claude/loop/rounds/N-slug.md`, the number unpadded. Plus a line in
`rounds/ROUNDS.md`.

This is the only home of the round record, of the verdict definitions, and of
what each verdict changes in the other files. The same record goes into the
round file, into the chat report, and (expanded) into the commit body.

**Contents:** the template, then a note per section (Target, Hypothesis, Before,
Mechanism, After, Canary, Gate, Not fixed, Links) · **The verdicts** — FIXED,
CLEAN, DEFERRED, INCONCLUSIVE, RETRACTED · **What a round changes** in the other
records, per verdict.

````
---
round: N
verdict: FIXED | CLEAN | DEFERRED | INCONCLUSIVE | RETRACTED
packages: [<the packages touched>]
lens: <ID from the project's set>
bench: P-N — reused | P-N — new | none
commit: yes | no
---

# Round N — <the topic in one line>

## Target

<what was chosen and why, weighed against what `next` reported. The script names
no target, so this section is the ONLY record of the judgement — "the oldest
never-applied lens" or "finishing B-23 before opening anything" are complete
answers; silence is not.>

## Hypothesis

<what may be wrong, phrased so that it can fail to hold>

## Before

```
<numbers: columns inside ``` , or rendering glues them into one paragraph>
```

Probe: `<file>` — without its name the measurement is not reproducible.

## Mechanism

<why it happens, one or two sentences>

## After

<numbers, the same probe>

## Canary

<witness> failed with "<the real message>" with the fix switched off

## Gate

<what was run and with what result>

## Not fixed

<what, and the reason: cost, risk or an owner decision>

## Links

<the lens, bench, leads, negatives and lessons the round touched, by ID>
````

**The verdict, the number and the packages go in the frontmatter, not in the
heading.** The heading carries only the topic: otherwise one fact lives in two
places and they diverge. `loop.py status` assembles the line for `ROUNDS.md` and
for chat from the frontmatter.

**A missing section is a sign of an unfinished round, not an abbreviation.** For
rounds with no fix, "After", "Canary" and "Gate" read as `n/a`, and "Before"
holds the negative result or a description of the bench that produced no number.


**Commit is `yes` or `no`, not a sha.** The round file rides in the same commit
as the fix, and the sha is unknown while the record is written. The commit body
starts with the line `Round N — <verdict> — <topic>` and then repeats the
record's sections; `git log --grep "Round N "` finds it (with the trailing
space — otherwise 204 also matches 2040), and `loop.py lint` checks that every
round with `commit: yes` has one.

The round file is what makes the loop transparent: the owner sees the round in a
diff, not in somebody's private memory.

## The verdicts

- **FIXED** — measured, fixed, re-measured, the canary did its job, the review
  approved, the gate is green, committed.
- **CLEAN** — measured with a control, nothing is broken. A full result, not a
  failure. Never pad out a clean round with cosmetics.
- **DEFERRED** — the defect is real and was deliberately not fixed. The reason
  must be cost, risk or an owner decision. "It was broken before us" is not a
  reason: it only says whether a regression was introduced, which changes the
  urgency and the commit text, not whether to fix it at all. Nor is a workaround
  acceptable: a `// pre-existing` comment, a loosened test, a relaxed threshold.
- **INCONCLUSIVE** — the bench produced no valid number within the round's
  budget: the control shows the same symptom, the probe shows zero where the
  mechanism could emit nothing, the result does not reproduce between runs. This
  is not CLEAN: "clean" with no valid control is hope, not a negative. A lead is
  filed with reason "bench" and a list of what was tried.
- **RETRACTED** — an earlier record turned out to be wrong. Say what the real
  cause was and which theories were disproven, so nobody tries them again.

## What a round changes

A file in `rounds/` always appears. Under any verdict: the round is written into
the `applied:` of the lens it used; a new valid bench becomes `P-N` in
`probes/`; a reused bench that stopped seeing the defect gets status
`broken (round N)`; a lesson with a price becomes `L-N` in `lessons/`; every
edit drags a line in its directory's index; `loop.py lint` is green. Then, by
verdict:

- **FIXED** — a commit; the lens gets status `confirmed (round N)` and
  evidence with numbers; the lead, if there was one, closes or gets
  `decided by owner (round N)`.
- **CLEAN** — no code commit; for a detector sweep the lens gets
  `swept here (round N, <sha>)`; for a check that is not about a shape, a new
  negative in `checked/`.
- **DEFERRED** — no commit; a new lead in `backlog/` with the reason: cost, risk
  or an owner decision.
- **INCONCLUSIVE** — no commit; the lens status does not change; a lead in
  `backlog/` with reason "bench" and a list of what was tried. A sweep that
  could not be carried out does not count as carried out.
- **RETRACTED** — a commit if prose is being corrected; the lens gets
  `retracted (round N)` with a reason; the record being retracted is edited in
  `backlog/`, `checked/` or `probes/`.

**A round that did not update what it used is not finished.**
