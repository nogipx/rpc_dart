---
name: improvement-loop
description: One round of a measured find-and-fix loop — pick a lens, take a probe, measure in numbers, fix, check with a canary, send it for review, run the gate, write it into the journal. Use it when asked to hunt bugs, leaks, security holes, hangs or performance problems; to continue or resume the improvement loop; to run a round, including on a schedule from /loop; to report the loop's status or where it stopped; to re-measure an earlier finding, deferral or "checked" mark; to derive or maintain the lens set; to lay the loop out in a new repository. It also fires without the word "loop" — on any "find what is broken" request about code.
allowed-tools: Read, Edit, Write, Glob, Grep, Agent, Task, CronList, CronDelete, Bash(python3:*), Bash(git status:*), Bash(git log:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*)
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
- **next** — name the next round's target and change nothing.
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

1. `python3 <skill>/scripts/loop.py next` — the round's target by the selection
   rules, valid benches along the same paths, the budget, the reading list.
   **The round number is the one the script named.** Not from memory, not from a
   commit, not from the user.
2. You may depart from `next`'s target — with the reason in the round's
   `## Target` section.
3. Read `config.md`, `LOOP.md` and `lessons/LESSONS.md` in full; the entity
   files as needed. The indexes exist so you can choose, not so you can know.

## Rule zero — a command must never ask for permission

With `unattended: yes`, a permission prompt stops the round dead. The mechanism
is the allowlist, not memory: this skill's `allowed-tools` plus
`permissions.allow` in `.claude/settings.json`, where `setup` mode writes the
toolchain, the gate and `loop.py`; `loop.py lint` checks the gate is covered.
Anything the allowlist does not cover — variables, substitutions, globs,
`| head`, `cd X &&`, `git stash`, `rm`, heredocs, reading files through the
shell instead of `Read` — is forbidden; the list and the reasons are in
`references/rule-zero.md`.

## Rule one — the code, not the prose

Any prose about code — comments, READMEs, CLAUDE.md, commits, this file, the
journal — is a secondary source and goes stale silently. The implementation
first; quote the prose only after the code has confirmed it; a divergence is a
defect, fixed in the same round. A comment justifying deliberateness is a lead,
not a closed door (U-01). The rule applies to the loop's own data in full: that
is what `lint` and `stale` are for.

## The round

1. **Target.** From `next`: an owner decision, then a lens never applied, then
   the rank, then a stale sweep. The catalog (`catalog/`) only through
   instantiation into the set. Before a sweep, check `checked/` and the
   statuses. A script detector is run through `loop.py sweep <ID>`; the list
   hash goes into the status.
2. **Bench.** `probes/` first — a valid bench along the same paths is reused,
   not rebuilt. A new bench counts as a bench once a control with the mechanism
   removed has shown it can see the defect; then it is registered as `P-NN`
   (`specs/probe.md`). The checklists are the universal
   `methods/measurement.md` plus the packs' items from `next`'s reading list.
   Every rebuild of the bench adds one to the `budget:` key; exhausted means the
   verdict is INCONCLUSIVE, not CLEAN.
3. **Measure in numbers.** No numbers, no defect.
4. **Fix.** Minimally, at the point that renders the wrong verdict.
5. **Re-measure** with the same probe on the same bench.
6. **Witness and canary.** `methods/canary.md`, `methods/tests.md`. Every
   attempt to get a failing witness adds one to `budget:`.
7. **Review — before the verdict.** A clean context checks the round record, the
   probe and the control against the prompt from `loop.py review` (the core from
   `references/review.md` plus the packs' questions): a subagent (`Agent`/
   `Task`), `claude -p` from a fork, otherwise yourself with an explicit note.
   Any "no" sends you back to step 2 with the same budget; the outcome goes into
   the `review:` key.
8. **Gate** with the full sequence from the config, **the record** per
   `specs/round.md` with every edit from "What a round changes", `loop.py lint`
   green, a commit with the same sections in its body, and a chat report with
   the same sections (`methods/reporting.md`). A lesson the round paid for
   becomes `L-NN` (`specs/lesson.md`); without a price in numbers it is not a
   lesson.

## The bar and the stop

The severity bar is set in the config and rises towards the end of the loop —
severity, not rigour. `status` computes the stop: the round cap, or every lens
swept and fresh with nothing to take from the backlog. Near the cap, do not open
work that spans several rounds: an unfinished tree is worse than one never
started.

## References — on demand

- **`specs/`** — what each file in `.claude/loop/` consists of; the verdicts and
  what each changes are in `specs/round.md`. Index: `specs/SPECS.md`.
- **`methods/`** — how to do the work: a checklist at the top, stories with
  numbers below. Index: `methods/METHODS.md`.
- **`catalog/`** — defect shapes by pack. Index: `catalog/CATALOG.md`.
- **`packs/`** — knowledge by domain and language: damage classes, checklist
  items, reviewer questions, detectors, probe templates. What is enabled is the
  `packs:` line in `config.md`; `loop.py` assembles them, the agent does not
  choose. Schema: `specs/pack.md`.
- **`references/`** — `model.md` (terms, diagrams), `rule-zero.md`, `review.md`
  (the core of the reviewer prompt).
- **`scripts/loop.py`** — `init`, `status`, `next`, `lint`, `stale`, `catalog`,
  `review`, `sweep`.
