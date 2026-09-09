# Methods

How to do the work. The schemas for what to write are in `../specs/`; the
universal defect shapes are in `../catalog/`. Each method opens with a checklist
of about a dozen lines, followed by the stories with numbers that explain why an
item is there. Always read the checklist; read the stories when an item is
unclear or a number surprises you.

- **[measurement.md](measurement.md)** — measurement discipline: reusing
  benches, where probes live, the two directions a metric lies in, RSS is not
  evidence of a leak, controls, performance, the budget and INCONCLUSIVE. The
  domain items (limits, latency, language forensics) are in `../packs/`. Before
  step 2.
- **[canary.md](canary.md)** — the canary protocol: witness versus guard, a fix
  in two halves, a guard that can fail open, re-measuring your own deferrals,
  reachability before shipping. Before step 5.
- **[tests.md](tests.md)** — how to write a regression test that will not lie:
  expectations and time, fixtures, state between tests, fake servers, honesty in
  the report. While the test is being written.
- **[reporting.md](reporting.md)** — the commit, comments beside the code, the
  chat report, and what must not be written. At step 7.
- **[lens-derivation.md](lens-derivation.md)** — how to build a lens set for an
  unfamiliar project; the selection rules `loop.py next` implements. `lenses`
  mode and step 1.
- **[curate.md](curate.md)** — data maintenance: rank, duplicates, staleness,
  benches, promoting lessons into the skill. `curate` mode.
- **[setup.md](setup.md)** — lay the loop out in a repository that has none.
  `setup` mode.
