# Checks on the skill itself

> Back to [SKILL.md](../SKILL.md). Run these after changing `SKILL.md`,
> [methods/](../methods/METHODS.md), [references/](../references/REFERENCES.md)
> or `scripts/loop.py` — they are what says the change did not regress the
> process.

**Contents:** the four mechanical checks, then the scenarios.

## The four checks, cheapest first

1. **`loop.py lint`** — the project's data against the schemas, and the skill's
   own link graph: every file reachable from `SKILL.md`, no dangling link, the
   gate covered by `permissions.allow`, `evals.json` well-formed.
2. **Run every command** — `status`, `next`, `stale`, `catalog`, `review`,
   `yield` — against the live journal. Python resolves a global when the line
   executes, so a name deleted from under a command is invisible to `lint`, to
   an import, and to reading the diff; it surfaces only on the call. Two such
   crashes shipped in one commit: `cmd_stale` read a `res` that no longer
   existed, and `cmd_init` called three templates that had been deleted with it.
3. **`init` in a scratch root**, then `status`, `next` and `lint` there:
   `python3 loop.py --root /tmp/x --loop /tmp/x/.claude/loop init`. This is the
   only way to exercise `setup` mode — the live repository already has a
   `.claude/loop/`, so `init` refuses, and its whole path stays untested. Expect
   `lint` to report exactly the gate placeholders that "Fill in `config.md`" in
   [methods/setup.md](../methods/setup.md) replaces.
4. **The scenarios below** — the judgement half, which no script can check.

Checks 1-3 are mechanical and take a minute; the crashes they catch are the ones
that stop a round dead. Check 4 catches the opposite kind: everything runs, and
the agent still does the wrong thing.

## The scenarios

`evals.json` holds twelve, each derived either from a rule the methods mark as
paid for by a mistake, or from machinery the skill added (the verdict check,
benches, lessons, stopping from `/loop`, packs, continuations, `next` reporting
state and deciding nothing). Run them through skill-creator or by hand: give an
agent the skill and a fixture repository, and compare against `expected_output`.
The skill counts as regressed if even one scenario produces a different outcome.

**Run them on a smaller model too.** Most of this skill is inferential — weigh
damage against reachability, decide what is worth finishing, tell a witness from
a guard — which is exactly what degrades first when the model gets smaller. A
scenario that only passes on the largest model is a scenario the skill does not
actually carry.

**A scenario that outlives the machinery it checks is worse than no scenario**:
it fails the skill for being current. When a step is deleted, its scenario goes
or is rewritten in the same edit — `lint` checks that `evals.json` parses and
that every scenario has an id, a name, a prompt and an `expected_output`, but
nothing can check that the expectation is still true.
