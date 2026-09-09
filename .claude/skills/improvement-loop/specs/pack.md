# Schema: a pack

> [Schemas](SPECS.md) · the packs themselves: [packs/](../packs/PACKS.md) ·
> where a pack sits in the model:
> [references/model.md](../references/model.md)

Path: `packs/<name>/` in the skill (shared across projects in a domain) or
`.claude/loop/packs/<name>/` in the project (private). Enabled by the `packs:`
line in `config.md`; `core` is always enabled.

A pack is a unit of knowledge, not of process. The round protocol, the entity
schemas, the verdicts, the stop condition and `lint` are the same in every
project and do not go into a pack; what goes into a pack is what speaks about a
domain or a language: a damage vocabulary, checklist items with their stories,
reviewer questions, detectors, probe templates.

```
packs/<name>/
  PACK.md          mandatory
  measure.md       items for the measurement.md checklist + stories
  canary.md        items for the canary.md checklist + stories
  tests.md         items for the tests.md checklist + stories
  review.md        reviewer questions, in a ``` block — `loop.py review` inserts them
  catalog/         U-N shapes with a `pack:` key (private packs only; the
                   skill packs' shapes live in the shared catalog/)
  assets/          probe and fixture templates for the toolchain
```

## PACK.md

```
---
applies: <under which properties of a project the pack makes sense>
damage classes: <comma separated; «—» if the pack adds none>
shapes: <IDs of the catalog shapes belonging to the pack; «—»>
contains: <which files exist and what is in them>
---

# <name> — <what it is about>
```

A value containing `: ` must be quoted:
`applies: "Dart code: pub packages"`. Otherwise it is not YAML, and a renderer
will show the frontmatter as text.

**Damage classes are matched as substrings** of a lens's `breaks:`, so write
them as bare nouns without articles: `crash`, not `a crash`.

## A catalog shape, `catalog/U-N-slug.md`

The same sections as a lens (`## Shape`, `## Detector`, `## Ask`,
`## Evidence`), with `pack`, `applies`, `breaks` and `status` in the
frontmatter.

## Rules

- **A pack's items are numbered with the pack's letter** (`A1`, `D2`), so a
  round record shows which pack a rule came from.
- **The bar is the same as for the methods**: an item and its story appear once
  a round has paid for them. A starter pack is a `PACK.md` with damage classes
  and a "starter" note; knowledge arrives from `lessons/` through `curate`.
- **Damage classes are a vocabulary, not knowledge**: they may be set up front,
  but say so.
- **A detector is a script** when the instance list can be produced
  programmatically; the protocol: run from the repository root, instances on
- **A private pack** is for knowledge that makes no sense outside this
  repository but does not fit into one lens or lesson. Anything that holds
  outside the repository is promoted by `curate` into a skill pack.
