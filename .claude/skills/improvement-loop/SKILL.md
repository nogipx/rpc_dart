---
name: improvement-loop
description: One round of a measured find-and-fix loop — pick a lens, take a probe, measure in numbers, fix, check the fix with a canary, run the gate, write it into the journal. Use it when asked to hunt bugs, leaks, security holes, hangs or performance problems; to continue or resume the improvement loop; to run a round, including on a schedule from /loop; to report the loop's status or where it stopped; to re-measure an earlier finding, deferral or "checked" mark; to derive or maintain the lens set; to lay the loop out in a new repository. It also fires without the word "loop" — on any "find what is broken" request about code.
allowed-tools: Read, Edit, Write, Glob, Grep, Agent, Task, CronList, CronDelete, Bash(python3 .claude/skills/improvement-loop/scripts/loop.py:*), Bash(git status:*), Bash(git log:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*)
---

# The improvement loop

One defect per round, start to finish. **A claim with no number is not a
finding. The bookkeeping is checked by a script, not by memory.** Everything
bound to the repository lives in `.claude/loop/`; this file knows nothing about
any particular project.

## Arguments and modes

The invocation's arguments: `$ARGUMENTS`. The first word is the mode; empty
means a **round**.

- **round** — steps 0-8 below.
- **status** — report the state below and change nothing.
- **next** — print the state a round chooses from, and change nothing. It
  names no target.
- **verify `<claim>`** — re-measure one record: a finding, a deferral, a
  negative, a sweep or a bench. A full round, with the lens that produced the
  record.
- **lenses** — derive or extend the lens set: `methods/lens-derivation.md`;
  `loop.py catalog` gives the catalog shapes for the enabled packs.
- **curate** — maintain the data: `methods/curate.md`. Once every ten rounds.
- **setup** — lay the loop out where there is no `.claude/loop/`:
  `methods/setup.md`.

## The state at invocation time

!`python3 .claude/skills/improvement-loop/scripts/loop.py status 2>/dev/null || python3 ~/.claude/skills/improvement-loop/scripts/loop.py status 2>/dev/null || echo "loop.py not found in .claude/skills/improvement-loop or ~/.claude/skills/improvement-loop — run status by hand from the skill's path"`

If the above says "no .claude/loop", the mode is `setup`. If it says "no lens
set", do `lenses` mode first. If it says **"Stop: YES"**, do not start a round:
report the reason and, if the call came from `/loop`, cancel the job
(`CronList`, `CronDelete`).

## Step 0 — read the state

1. `python3 <skill>/scripts/loop.py next` — the lens set with its statuses and
   `applied:` history, what git says moved under a swept lens, the open leads,
   the valid benches, the budget, the reading list. **The round number is the one
   the script named.** Not from memory, not from a commit, not from the user.
2. `next` reports FACTS, not a recommendation — the script computes what memory
   gets wrong (what git says moved, what is unreferenced, what was applied when)
   and stops there. Weighing severity, reachability and what is worth finishing
   is yours. **The one thing it still decides is the round cap**, because an
   unattended agent asked "should we continue?" always says yes.
3. Read `config.md`, `LOOP.md` and `lessons/LESSONS.md` in full; the entity
   files as needed. The indexes exist so you can choose, not so you can know.
   **In `methods/`, read the checklist at the top of each file** — the stories
   below it explain what each item cost and are worth reading once, not once per
   round.

## Rule zero — a command must never ask for permission

With `unattended: yes`, a permission prompt stops the round dead. The mechanism
is the allowlist, not memory: this skill's `allowed-tools` plus
`permissions.allow` in `.claude/settings.json`, where `setup` mode writes the
toolchain, the gate and `loop.py`; `loop.py lint` checks the gate is covered.
Anything the allowlist does not cover — variables, substitutions, globs,
`| head`, two commands joined by `;` or `&&`, `git stash`, `rm`, heredocs,
reading files through the shell instead of `Read` — is forbidden; the list and
the reasons are in `references/rule-zero.md`. **One command per `Bash` call**:
a chain matches no prefix rule, so welding `echo "EXIT=$?"` onto an allowed
command is what makes it ask.

**No program written on the command line.** `python3` is allowlisted for
`scripts/loop.py` and nothing else — never `python3 -c`, `-e`, `node -e`,
`dart -e` or a heredoc. A one-liner in a shell argument is a script authored
outside `Write`, unreviewable in the diff, and it is why the rule is enforced by
a NARROW allowlist rather than by remembering: `lint` rejects a bare
`Bash(python3:*)` wherever it finds one. Same for backgrounding (`cmd &`,
`( … & )`) and redirecting output into a file: both prompt, and both hide the
output the round is supposed to record.

## Rule one — the code, not the prose

Any prose about code — comments, READMEs, CLAUDE.md, commits, this file, the
journal — is a secondary source and goes stale silently. The implementation
first; quote the prose only after the code has confirmed it; a divergence is a
defect, fixed in the same round. A comment justifying deliberateness is a lead,
not a closed door (U-01). The rule applies to the loop's own data in full: that
is what `lint` and `stale` are for.

**NEVER rely on documentation. Only on the actual code.** No exceptions, and in
particular none for prose that carries NUMBERS. A doc comment with a measured
table in it reads exactly like evidence and is not: it is a record of a
measurement someone took, on a tree that has since moved, and nothing checks it.

## The round

1. **Target. THE SCRIPT DOES NOT CHOOSE.** `next` prints state, in no order and
   naming nothing: lenses with their status and `applied:` history, swept lenses
   whose files have moved, open leads, valid benches, any owner decision.
   **You decide; `## Target` records what you took and why.** Encoding that
   judgement as precedence cost rounds 234-238 — five rounds opening new threads
   while a started one sat unfinished. `loop.py yield` says which lenses have
   ever paid. Before a sweep check `checked/`; the catalog only through
   instantiation into the set.
2. **Bench.** `probes/` first — a valid bench along the same paths is reused,
   not rebuilt. A new bench counts as a bench once a control with the mechanism
   removed has shown it can see the defect; then it is registered as `P-N`
   (`specs/probe.md`). The checklists are the universal
   `methods/measurement.md` plus the packs' items from `next`'s reading list.
   **A bench that could not see the defect makes the verdict INCONCLUSIVE, not
   CLEAN** — however many times it was rebuilt.
3. **Measure in numbers.** No numbers, no defect.
4. **Fix.** Minimally, at the point that renders the wrong verdict.
   **The narrative does not go beside the code.** The round record and the commit
   body already hold the measurement, the controls and the story; repeating them
   in a comment inflates the file every round forever. A comment earns its place
   by saying what BREAKS if this is undone — one or two lines. Measured on four
   consecutive fixes that ignored this: 19-37% of every diff was comment,
   including tables copied verbatim from the round record.
5. **Re-measure** with the same probe on the same bench.
6. **Witness and canary.** `methods/canary.md`, `methods/tests.md`. **No failing
   witness, no fix**: if the fix cannot be switched off and shown to break
   something, it is not proven.
7. **Check the verdict.** Answer what `loop.py review` prints — seven questions
   plus the enabled packs' — in writing, against your own record, probe and
   control; any "no" sends you back to **Bench**. Q2 — *did the control show the
   bench can SEE the defect* — is the one that catches things. (This once
   demanded "a clean context" and a `review:` key; 39 of 39 rounds wrote
   `review: self`, so the ceremony went and the questions stayed.)
8. **Gate** with the full sequence from the config, **the record** per
   `specs/round.md` with every edit from "What a round changes", `loop.py lint`
   green, **ONE commit** with the same sections in its body — everything the
   round produced rides in it, and a correction to what this round already
   committed is an `--amend`, not a second commit — and a chat report with the
   same sections (`methods/reporting.md`).
   **Then run `lint` AGAIN, after committing**, and read the commit back
   (`git log -1 --name-only`). The sprawl check compares the new commit against
   the previous one, so `lint && git commit` measures a state that no longer
   exists and always passes. Red afterwards means squash and recommit. A lesson the round paid for
   becomes `L-N` (`specs/lesson.md`); without a price in numbers it is not a
   lesson.

## The bar and the stop

The severity bar is set in the config and rises towards the end of the loop —
severity, not rigour. **The round cap is the only stop the script enforces**,
and it exists for unattended runs: an agent asked "should we continue?" always
says yes. Everything else — whether the set is worked out, whether a lead is
worth taking — is your call from the state `next` prints. Near the cap, do not
open work that spans several rounds: an unfinished tree is worse than one never
started.

## References — on demand

Each directory has an index; `loop.py lint` fails on anything unreachable from
here or on a dangling link.

- **[specs/](specs/SPECS.md)** — what each file in `.claude/loop/` consists of,
  one file per record type, opened when writing that record: the verdicts and
  what each changes are in [round.md](specs/round.md); the others are
  `specs/lens.md`, `probe.md`, `backlog-item.md`, `checked-item.md`,
  `lesson.md`, `config.md`, `pack.md`.
- **[methods/](methods/METHODS.md)** — how to do the work. **Checklist at the
  top of each file; the stories below it are read once, not once per round.**
  The three read every round are linked here directly rather than through the
  index, because a file reached through two hops tends to get previewed instead
  of read: [measurement.md](methods/measurement.md) (the Bench step),
  [canary.md](methods/canary.md) (Witness and canary),
  [tests.md](methods/tests.md) (writing the regression test).
- **[catalog/](catalog/CATALOG.md)** — defect shapes by pack, one file per
  shape, consulted BY ID when a lens names one in `refines:`. Open it directly
  (`catalog/U-07-*.md`) or search across them rather than reading the index
  first: `grep -rl "abort" catalog/`.
- **[packs/](packs/PACKS.md)** — knowledge by domain and language; the `packs:`
  line in `config.md` selects them, and `loop.py next` names the exact pack
  files for the round. Schema: [specs/pack.md](specs/pack.md).
- **[references/](references/REFERENCES.md)** —
  [model.md](references/model.md) (terms),
  [rule-zero.md](references/rule-zero.md),
  [review.md](references/review.md) (the seven questions).
- **[evals/](evals/EVALS.md)** — scenarios that check the skill itself. Run them
  after changing this file or `methods/`.
- **`scripts/loop.py`** — `init`, `status`, `next`, `lint`, `stale`, `catalog`,
  `review`, `yield`. **Every one reports facts; only the round cap decides.**

**Refer to a step by NAME, never by number** — the numbering moves, and `lint`
rejects `step <N>` everywhere but here.
