# Checks on the skill itself

> Back to [SKILL.md](../SKILL.md). Run these after changing `SKILL.md`,
> [methods/](../methods/METHODS.md), [references/](../references/REFERENCES.md)
> or `scripts/loop.py` — they are what says the change did not regress the
> process.

**Contents:** the four mechanical checks, then the scenarios.

## The four checks, cheapest first

1. **`loop.py selftest`** — this file's own assertions against a fixture, with
   no `.claude/loop/` needed, so it also runs in a repository that has not been
   set up. It covers what has actually broken here: names a function reads but
   nothing binds, which surfaces as a NameError mid-round; the anchored
   `round_key` grammar; the permission prefix matching rule zero stands on;
   `init` in a temp root,
   including its refusal to lay out on top of data — the one path a live
   repository can never exercise; that what `init` writes satisfies what `lint`
   demands; that traits admit and hold back the right items; and that every path
   `brief` and `review` concatenate exists and is non-empty.

   It also checks the MIRROR of the unbound-name rule — **a function defined and
   never read**. That one earned its place immediately: it found `resolve_script`,
   left behind by the detector scripts deleted in September 2026 and still
   taking a `packs` dict in a shape the traits redesign had replaced, and then
   `_overlap`, dead since the selector stopped ranking. Neither is a crash,
   which is exactly why nothing noticed them.

   It is a subcommand rather than a `tests/` directory with its own runner
   because of rule zero: the allowlist grants `python3 <path to loop.py>`, so a
   second script would need a second permission rule in every repository, for a
   command only whoever edits the skill ever runs.
2. **`loop.py lint`** — the project's data against the schemas, the skill's own
   link graph (every file reachable from `SKILL.md`, no dangling link), the gate
   covered by `permissions.allow`, and `evals.json` well-formed. Needs a real
   journal, which is why it comes after selftest.
3. **Run every command** — `status`, `next`, `brief`, `stale`, `catalog`,
   `review`, `yield` — against the live journal. Checks 1 and 2 catch the
   deleted-name and dangling-link classes statically; running catches what they
   cannot see: a wrong assumption about the data's shape, a branch that only
   fires on real records, output that contradicts what the docs say the command
   does. For `brief` and `review`, read the OUTPUT: the failure mode of
   concatenation is a half that silently did not arrive, and a checklist missing
   its trait-gated items still looks like a checklist.
4. **The scenarios below** — the judgement half, which no script can check.

Checks 1-3 are mechanical and take a minute; the crashes they catch are the ones
that stop a round dead. Check 4 catches the opposite kind: everything runs, and
the agent still does the wrong thing.

## The scenarios

`evals.json` holds fifteen, each derived either from a rule the methods mark as
paid for by a mistake, or from machinery the skill added (the verdict check,
benches, lessons, stopping from `/loop`, traits selecting items, a project
extending the trait vocabulary, continuations, `next` reporting state and
deciding nothing, `brief` replacing the reading list, `selftest` guarding edits
to the script). Run them through skill-creator or by hand: give an agent the
skill and a fixture repository, and compare against `expected_output`. The skill
counts as regressed if even one scenario produces a different outcome.

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
