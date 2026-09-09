# Schema: a lens

Path: `.claude/loop/lenses/<PREFIX>-N-slug.md`. Plus a line in
`lenses/LENSES.md`. Each set has its own prefix (`RPC-`, `WEB-`); the universal
catalog uses `U-`.

A lens is not a rule and not advice. It is a **hypothesis generator**: a shape
of code, plus a way to find its instances, plus the question that separates a
real defect from a harmless coincidence.

Lenses belong to the project. The skill owns the schema, the catalog of shapes
and the order of application; only somebody who knows the code knows the
concrete detectors.

## Mandatory fields

```
---
refines: <ID of the universal shape> if the lens instantiates one; otherwise «—»
paths: [<the globs the detector covers>]
applies: <under which properties of the project the lens makes sense at all>
breaks: <damage class>
applied: [<round numbers>]
status: derived | confirmed (round N) |
        swept here (round N, <sha>[, sweep <hash>]) | retracted (round N)
detector-script: <path> [arguments]        # optional
---

# <ID> — <short name>

## Shape

What the construct is, described so it can be recognised in unfamiliar code. Not
"bad code" but a concrete structure.

## Detector

How to find the instances in this project: a grep pattern, an enumeration of a
dependency's public API, a list of entry points, a behavioural battery.
Concretely, down to the symbols and paths.

## Ask

The question that separates a defect from a harmless instance. It must have an
answer obtained by measurement rather than by reasoning.

## Evidence

What the lens found and how big it was. «—» for a derived lens.
```

On individual keys:

- **`paths`** — `stale` uses them to tell whether the code changed since the
  last sweep: `[lib/src/transport/**, lib/src/flow/*.dart]`.
- **`breaks`** — a damage class from the enabled packs and the config's
  `damage classes:` (`loop.py catalog` prints the union); `lint` warns about a
  class outside that vocabulary.
- **`applied`** — the back-reference to a round's `lens:` key; `lint` reconciles
  them, and step 1 uses the number of entries to pick the least-explored one.
- **`detector-script`** — when the detector is a script printing one instance
  per line. The path is relative to the skill, a pack or `.claude/loop/`. Then
  `loop.py sweep` performs the sweep and `stale` compares the lists. The
  `## Detector` section is still mandatory: the script says WHERE, not WHAT to
  look for.

**An off-journal round.** If a round happened but its record does not exist (the
journal was not started at the first one — see `../methods/setup.md`), the
number is marked: `confirmed (round 162, off-journal)`,
`swept here (round 121, off-journal)` — with no sha there, because the state of
the code at that moment is unknown. The same in `applied:`:
`[162 off-journal, 189 off-journal]`.

The marker does not remove the check, it narrows it: `lint` requires the number
to be BELOW the journal's first round. Otherwise it could be used to bury a
recent record that went missing. `stale` always shows an «off-journal» sweep as
needing a re-measurement: there is nothing to age it against.

## The quality bar

A lens is not accepted into the set if:

- **it has no detector.** "Look for wrong resource accounting" is a horoscope. A
  detector must yield a finite list of places that can be walked;
- **it has no paths.** Without them a sweep cannot be aged, and `swept here`
  would be true forever, which never happens;
- **the question is not measurable.** If `## Ask` is answered by reading and
  opinion, it is taste, not a lens;
- **no damage class is named.** A lens whose finding cannot clear the severity
  bar wastes a round;
- **it restates another one.** Refining an existing shape is expressed by the
  `refines: <ID>` key, not by a new record.

## Statuses and how they change

- **derived** — a hypothesis. Everything invented by analysing the code rather
  than by a finding is marked this way.
- **confirmed (round N)** — a round found a real defect through it. Only then
  does the `## Evidence` section fill with numbers.
- **swept here (round N, sha[, sweep hash])** — the sweep by its detector came
  back clean on the code at `sha`. This is not a deletion: the record stays so
  the next round does not repeat the sweep, and `loop.py stale` says when new
  code appeared along the lens's paths. With a script detector the status also
  stores the hash of the instance list (printed by `sweep`): then the ageing is
  computed from the list rather than from the paths, and a new instance of the
  shape is seen exactly.
  **This is the only home of such a fact**: `checked/` holds only negatives that
  are not tied to a shape.
- **retracted (round N)** — the shape turned out not to be a defect. The
  reason is recorded, or the lens will be derived again.

INCONCLUSIVE does not change the status, but the round is still written into
`applied:`.

How to build a set for an unfamiliar project, how to pick a lens from the data,
and how to maintain the set — `../methods/lens-derivation.md`.
