# Methods

> Back to [SKILL.md](../SKILL.md) · what to WRITE is
> [specs/](../specs/SPECS.md) · the universal defect shapes are
> [catalog/](../catalog/CATALOG.md) · the domain items that extend these
> checklists come from [packs/](../packs/PACKS.md)

How to do the work. Each method opens with a checklist of about a dozen lines,
followed by the stories with numbers that explain why an item is there. Always
read the checklist; read the stories when an item is unclear or a number
surprises you.

**Steps are named, never numbered.** The numbering in `SKILL.md` moves whenever
a step is added, and a number written down here goes silently wrong — it already
had, twice, before `loop.py lint` started rejecting it.

- **[measurement.md](measurement.md)** — measurement discipline: reusing
  benches, where probes live, the two directions a metric lies in, RSS is not
  evidence of a leak, controls, performance, the budget and INCONCLUSIVE. The
  domain items (limits, latency, language forensics) are in
  [../packs/](../packs/PACKS.md). At the **Bench** step, before measuring.
- **[canary.md](canary.md)** — the canary protocol: witness versus guard, a fix
  in two halves, a guard that can fail open, re-measuring your own deferrals,
  reachability before shipping. At the **Witness and canary** step.
- **[tests.md](tests.md)** — how to write a regression test that will not lie:
  expectations and time, fixtures, state between tests, fake servers, honesty in
  the report. While the test is being written.
- **[reporting.md](reporting.md)** — the commit, comments beside the code, the
  chat report, and what must not be written. At the **Gate** step, with the
  record.
- **[lens-derivation.md](lens-derivation.md)** — how to build a lens set for an
  unfamiliar project; the selection rules `loop.py next` implements. `lenses`
  mode, and the **Target** step of an ordinary round.
- **[curate.md](curate.md)** — data maintenance: rank, duplicates, staleness,
  benches, promoting lessons into the skill. `curate` mode.
- **[setup.md](setup.md)** — lay the loop out in a repository that has none.
  `setup` mode.
