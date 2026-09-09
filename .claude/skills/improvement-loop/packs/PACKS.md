# Packs — knowledge by domain

Back to [SKILL.md](../SKILL.md). The schema for a pack is
[specs/pack.md](../specs/pack.md); where a pack sits in the model is
[references/model.md](../references/model.md).

A pack is **not a loop entity**. It is a unit of knowledge: a damage vocabulary,
checklist items appended to the universal [methods](../methods/METHODS.md),
questions appended to the verdict check
([references/review.md](../references/review.md)),
and catalog shapes. Which packs are live is the `packs:` line
in the project's `config.md`; `scripts/loop.py` assembles them and the agent does
not choose.

A pack can also live in the project — `.claude/loop/packs/<name>/` — and the
script looks in both places, the project's copy first.

## Enabled by domain

- **[core](core/PACK.md)** — holds in any code; always enabled. 14 shapes.
- **[async-io](async-io/PACK.md)** — two sides, a channel, limits, waits. 7
  shapes plus its own measure, canary, tests and review items. Everything in it
  was paid for by rounds on a transport library.
- **[dart](dart/PACK.md)** — language and runtime idioms: pub packages,
  dart2js/AOT targets, isolates. Measure and tests items, and a probe skeleton.
- **[server](server/PACK.md)** — a long-lived process with connections, storage
  and restarts. A starter pack: damage classes only, no shape has been paid for
  yet.
- **[crdt](crdt/PACK.md)** — several replicas, coordination-free merge,
  offline-first. A starter pack.
- **[flutter-ui](flutter-ui/PACK.md)** — an app with screens, navigation and
  input. A starter pack.

## How a pack grows

A starter pack fills up through [lessons](../specs/lesson.md) and the
[curate](../methods/curate.md) pass: a lesson that holds outside the project it
was paid for is promoted into the pack or into the universal method. A shape
lands in the [catalog](../catalog/CATALOG.md) only once a real finding has paid
for it, and the shape's `pack:` key is what makes it available to a project that
enables that pack.
