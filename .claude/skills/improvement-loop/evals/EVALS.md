# Checks on the skill itself

> Back to [SKILL.md](../SKILL.md). Run these after changing `SKILL.md`,
> [methods/](../methods/METHODS.md) or [references/](../references/REFERENCES.md)
> — they are what says the change did not regress the process.

`evals.json` holds twelve scenarios, each derived either from a rule the methods
mark as paid for by a mistake, or from machinery the skill added (the verdict
check, benches, lessons, stopping from `/loop`, packs, continuations, `next`
reporting state and deciding nothing). Run them through skill-creator or by
hand: give an agent the skill and a fixture repository, and compare against
`expected_output`. The skill counts as regressed if even one scenario produces a
different outcome.

**A scenario that outlives the machinery it checks is worse than no scenario**:
it fails the skill for being current. When a step is deleted, its scenario goes
or is rewritten in the same edit — `loop.py lint` checks that `evals.json`
parses and that every scenario has an id, a name, a prompt and an
`expected_output`, but nothing can check that the expectation is still true.
