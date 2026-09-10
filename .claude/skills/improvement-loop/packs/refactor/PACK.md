---
applies: a round whose target is the shape of the code rather than a defect in it — doc comments, public surface, abstractions
damage classes: wrong result, unbounded growth
shapes: U-22, U-23
contains: shapes for refactor mandates; enable alongside core, never instead of it
---

# refactor — when the target is the shape, not the defect

> [Packs](../PACKS.md) · schema: [specs/pack.md](../../specs/pack.md) · its
> shapes live in [catalog/](../../catalog/CATALOG.md)

Every other pack asks *what is broken*. This one is for a mandate that asks
*what is unclear, unbounded or unowned* — and it exists because a round without
such a lens reaches for the worst file it can see instead of auditing the
surface.

**The severity bar does not apply here and the measurement discipline still
does.** A refactor round takes work the bar would refuse — a doc comment, an
export list — so the config's "only very critical" is suspended by the mandate.
Nothing else is: `## Before` is still a number, the analyzer or the surface
count is still the witness, and the gate is still green before the commit.

Two numbers make a refactor round measurable, and both are cheap:

- **doc lines against total lines**, per file and per package (U-22)
- **public top-level types**, and how many of them anything outside the
  implementation actually uses (U-23)

Neither needs a probe, which is why a refactor round records `bench: none`
without that being a gap.
