# Schema: a bench

> [Schemas](SPECS.md) · a probe becomes a bench once a control validates it:
> [methods/measurement.md](../methods/measurement.md)

Path: `.claude/loop/probes/P-N-slug.md`. Plus a line in `probes/PROBES.md`.

A bench is the most expensive thing in a round and the only one the skill used
to throw away. A probe becomes a bench the moment a control with the suspected
mechanism removed shows it is able to see the defect. From then on it has a
record, and the next round on the same paths starts from it.

````
---
file: <path to the probe file in the repository; a probe outside git is fine>
round: N — the validating round
commit: <the HEAD sha at the moment of validation>
paths: [<globs of the code the bench exercises>]
status: valid | stale (sha) | broken (round N) — does not see the defect, reason
---

# P-N — <what it measures, briefly>

<how to run it, what to change for another hypothesis — three to five lines>

## Measures

One number, in words: what is counted and on which side.

## Control

How the suspected mechanism is removed and what the control showed at
validation:

```
<numbers — this is what makes a bench different from a probe>
```
````

`next` matches a bench to a lens by `paths`, and `stale` computes the ageing
from them.

**A bench without a control is a probe, not a bench**, and gets no record.

**A bench goes stale** — that is the story where an in-memory pair silently
zeroed out a race: a round reusing a bench repeats its control first. Once the
control stops differing from the case under test, the status becomes
`broken (round N)`, the bench is rebuilt, and that is a measurement rather
than a punishment. The probe file may vanish along with the working tree; the
record stays and `lint` warns.

**One bench, many hypotheses.** A lens and a bench are linked by paths, not one
to one: a flow-control bench serves every flow-control lens.
