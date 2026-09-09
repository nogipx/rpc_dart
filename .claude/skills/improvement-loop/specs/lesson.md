# Schema: a lesson

> [Schemas](SPECS.md) · promoted into the skill by
> [methods/curate.md](../methods/curate.md), where it becomes a
> [catalog](../catalog/CATALOG.md) shape or a [pack](../packs/PACKS.md) item

Path: `.claude/loop/lessons/L-N-slug.md`. Plus a line in `lessons/LESSONS.md`.

A lesson is a rule for working with this code that a round paid for: with a
rebuilt probe, a retracted verdict, a canary that took two attempts, a gate that
failed on a known trap. The bar is the same as for the skill's methods: without
a price in numbers it is an opinion, not a lesson. A diary, observations "for
the future" and restatements of `CLAUDE.md` do not belong here.

```
---
round: N — where it was paid for
class: bench | toolchain | fixture | metric | process
cost: <what was lost, in numbers: probe rebuilds, rounds, minutes of gate>
paths: [<globs of the code the lesson is about>]     # «—» if not about code
commit: <the HEAD sha at the moment of the round>
status: active | promoted to skill (<file in the skill>) | obsolete (round N)
---

# L-N — <the rule in one phrase, imperative>

<what happened, what it turned out to be, what to do differently — three
sentences>
```

**The boundary with the other homes.** A toolchain trap the owner accepted as
permanent moves to `config.md`; the lesson gets `obsolete (round N)` with a
link. A rule that holds in any code is promoted by `curate` mode into the
skill's `methods/` or `catalog/`; the lesson gets
`status: promoted to skill (<file>)` and stays in the project as a link — the
one-home rule.

**They are read in full when the round reads its state** — one index line per
lesson. More than
twenty active lessons is a reason for `curate`: merge, promote, retire.
