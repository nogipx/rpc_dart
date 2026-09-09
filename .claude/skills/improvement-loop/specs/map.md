# Schema: the data map

> [Schemas](SPECS.md) · written by [methods/setup.md](../methods/setup.md) ·
> the indexes it points at: [index.md](index.md)

Path: `.claude/loop/LOOP.md` — the name matches the directory by the general
rule.

The way in for someone who arrives at the data without this skill: it must make
clear what to look for where, and how one thing links to another.

It contains:

1. **One sentence about what this data is**, and a link to the skill for the
   rules.
2. **The six entities** — one line each: which question it answers, where it
   lives, where its index is.
3. **The link diagram** — a small mermaid diagram: who points at whom.
4. **"Where to go with a question"** — the scenarios: I want to run a round,
   what the next number is and which target to take (`loop.py status`,
   `loop.py next`), has this been checked, is there a ready bench, what we
   learned on this code, where a claim came from, what awaits the owner and how
   to answer (the `## Owner decision` section).
5. **"What to trust with care"** — what is true of this data: unrecovered
   history, records marked "not re-measured", detectors never run.

**Navigation only, no rules.** The rules live in the skill; a map that explains
the model will diverge from it at the first edit. `loop.py init` creates a map
with items 1-4 filled in; item 5 is written by hand at setup.
