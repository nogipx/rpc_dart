# Methods

> Back to [SKILL.md](../SKILL.md) · what to WRITE is
> [specs/](../specs/SPECS.md) · the universal defect shapes are
> [catalog/](../catalog/CATALOG.md) · the domain items that extend these
> checklists come from [items/](../items/ITEMS.md)

How to do the work.

**The three checklists read every round are not read as files.**
`python3 scripts/loop.py brief` prints all three with the project's domain items
concatenated in place — whichever the `traits:` in `config.md` admit — which is
one command instead of eight file opens and removes the chance of reading the
universal list without its domain half. Each checklist file therefore holds
items and NOTHING else — no title prose, no breadcrumb — and what paid for each
item lives in the `-why` file beside it.

**`brief` also names what it held back**, item by item, with the trait that
would have admitted it. Read that list: an item waiting on an undeclared trait
is knowledge that exists and did not arrive, and a checklist that is quietly
short looks exactly like a complete one.

Open a `-why` when its item is the one biting. That split is what makes "read
the checklist, not the story" a property of the layout rather than an
instruction to be remembered: measured before it, the three checklists were 980
words of items inside 4020 words of prose, re-read every round.

**Steps are named, never numbered.** The numbering in `SKILL.md` moves whenever
a step is added, and a number written down here goes silently wrong — it already
had, twice. The steps carry bold names for exactly this reason; cite those.

- **[measurement.md](measurement.md)** — the Bench checklist: reusing benches,
  which side a number came from, RSS is not evidence of a leak, the budget and
  INCONCLUSIVE. Printed by `brief`; the stories are in
  [measurement-why.md](measurement-why.md). The domain items (limits, latency,
  language forensics) come from [../items/](../items/ITEMS.md).
- **[canary.md](canary.md)** — the canary protocol, at the **Witness and
  canary** step: witness versus guard, a fix in two halves, a guard that can
  fail open, reachability before shipping. Printed by `brief`; the stories are
  in [canary-why.md](canary-why.md).
- **[tests.md](tests.md)** — how to write a regression test that will not lie,
  while the test is being written: expectations and time, fixtures, state
  between tests. Printed by `brief`; the stories are in
  [tests-why.md](tests-why.md).
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
