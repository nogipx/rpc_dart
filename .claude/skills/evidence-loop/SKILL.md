---
name: evidence-loop
description: One round of a find-and-fix loop where nothing counts without confirmed evidence — pick a lens, take a probe, confirm it with a control, fix, canary the fix, run the gate, write it into the journal. Use it when asked to hunt bugs, leaks, security holes, hangs or performance problems; to continue or resume the loop; to run a round, including on a schedule from /loop; to report the loop's status or where it stopped; to re-measure an earlier finding, deferral or "checked" mark; to derive or maintain the lens set; to lay the loop out in a new repository. It also fires without the word "loop" — on any "find what is broken" request about code.
allowed-tools: Read, Edit, Write, Glob, Grep, Agent, Task, CronList, CronDelete, Bash(python3 .claude/skills/evidence-loop/scripts/loop.py:*), Bash(git status:*), Bash(git log:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*)
---

# The evidence loop

One defect per round, start to finish. **A claim with no CONFIRMED evidence is
not a finding. The bookkeeping is checked by a script, not by memory.**

Confirmed means something was varied and the outcome changed: a control with the
mechanism removed, an ablation that kills a guard, a witness that fails with a
real message. A number is the usual form of that and the sharpest one — reach
for it first, and it is the only evidence that compares across rounds — but it
is not the only admissible one, and a round whose evidence is a clean ablation
is not a weaker round. What is never a finding is a claim nothing was varied
against.

**Which is why the canary is not negotiable, and least of all on a round with no
number.** Switching the fix off in place and watching the witness fail IS the
variation; where there is no quantity it is the only confirmation the round has.
`## Canary` empty on a FIXED round is an error, not a warning, and that has not
moved.

Everything bound to the repository lives in `.claude/loop/`; this file knows
nothing about any particular project.

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
  `loop.py catalog` gives every catalog shape — nothing filters that list.
- **curate** — maintain the data: `methods/curate.md`. Once every ten rounds.
- **setup** — lay the loop out where there is no `.claude/loop/`:
  `methods/setup.md`.

## The state at invocation time

!`python3 .claude/skills/evidence-loop/scripts/loop.py status 2>/dev/null || python3 ~/.claude/skills/evidence-loop/scripts/loop.py status 2>/dev/null || echo "loop.py not found in .claude/skills/evidence-loop or ~/.claude/skills/evidence-loop — run status by hand from the skill's path"`

If the above says "no .claude/loop", the mode is `setup`. If it says "no lens
set", do `lenses` mode first. If it says **"Stop: YES"**, do not start a round:
report the reason and, if the call came from `/loop`, cancel the job
(`CronList`, `CronDelete`).

## Step 0 — read the state

1. `python3 <skill>/scripts/loop.py next` — the lens set with its statuses and
   `applied:` history, what git says moved under a swept lens, the open leads,
   the valid benches, what each lens has ever produced, the budget. **The round
   number is the one the script named.** Not from memory, not from a commit, not
   from the user.
2. `next` reports FACTS, not a recommendation — the script computes what memory
   gets wrong (what git says moved, what is unreferenced, what was applied when)
   and stops there. Weighing severity, reachability and what is worth finishing
   is yours. **The one thing it still decides is the round cap**, because an
   unattended agent asked "should we continue?" always says yes.
3. `python3 <skill>/scripts/loop.py brief` — the three checklists a round works
   from (Bench, Witness and canary, the regression test), each printed with this
   project's domain items already merged into it — whichever the `traits:` in
   `config.md` admit. **One command, not eight files**, and the domain half can
   no longer arrive without its universal half. What paid for an item is in the
   `-why` file beside each checklist: open one when that item is the one biting,
   not once per round. **Read what it says it held back**: an item waiting on a
   trait the project has not declared is knowledge that exists and did not
   arrive, and a short checklist looks exactly like a complete one.
4. Read `config.md` and `lessons/LESSONS.md` in full; `LOOP.md` for navigation
   and for its "What to trust with care"; the entity files as needed. The
   indexes exist so you can choose, not so you can know.

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
   (`specs/probe.md`). The checklist is what `loop.py brief` printed under
   `measure`, universal items and this project's packs' together.
   **A bench that could not see the defect makes the verdict INCONCLUSIVE, not
   CLEAN** — however many times it was rebuilt.
3. **Measure.** In numbers wherever a number exists — they are the sharpest
   evidence and the only kind that compares across rounds. Where the finding is
   not a quantity, the evidence is still something VARIED whose outcome changed:
   an ablation, a witness, a sweep that names every site. No confirmation, no
   defect.
4. **Fix.** Minimal in DEPTH, complete in BREADTH — and those are different
   axes. Minimal means one mechanism, at the point that renders the wrong
   verdict; it does NOT mean a convenient subset of the instances.
   **Sweep the whole surface of the class before writing the record.** Count the
   instances first — `grep` the shape across every package the lens's `paths:`
   name — then fix all of them, or say in `## Not fixed` exactly how many are
   left, where, and why, with the number. A round that fixes the instances it
   happened to be looking at and calls the rest "remaining work" has shifted the
   job to the owner without saying so; that is an under-delivery even when every
   number in the record is true. If the full sweep is genuinely too large for one
   round, that is a fact to state up front, not to discover at the end.
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
   plus the domain ones the traits admit — in writing, against your own record, probe and
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

**"Too large for one round" is a measurement, not a feeling, and it is taken
BEFORE the fix.** Count the instances, decide the scope, and put the scope in
`## Target` — "all 58 sites" or "the 16 on the per-call path, because the other
42 are X and cost Y". Deciding it afterwards, from whatever got done, is how a
round ends up reporting a subset as if it were the job. When the owner asked
about a class of defect, the class is the scope; narrowing it is their call to
make, not yours to assume.

## References — on demand

Each directory has an index; `loop.py lint` fails on anything unreachable from
here or on a dangling link.

- **[specs/](specs/SPECS.md)** — what each file in `.claude/loop/` consists of,
  one file per record type, opened when writing that record: the verdicts and
  what each changes are in [round.md](specs/round.md); the others are
  `specs/lens.md`, `probe.md`, `backlog-item.md`, `checked-item.md`,
  `lesson.md`, `config.md`.
- **[methods/](methods/METHODS.md)** — how to do the work. The three checklists
  a round uses are **not read as files**: `loop.py brief` prints them with the
  packs merged in. Each holds items and nothing else
  ([measurement.md](methods/measurement.md), [canary.md](methods/canary.md),
  [tests.md](methods/tests.md)); what paid for each item is beside it
  ([measurement-why.md](methods/measurement-why.md),
  [canary-why.md](methods/canary-why.md),
  [tests-why.md](methods/tests-why.md)), read when an item bites. The rest of
  the methods — [reporting.md](methods/reporting.md),
  [lens-derivation.md](methods/lens-derivation.md),
  [curate.md](methods/curate.md), [setup.md](methods/setup.md) — are opened for
  the step or the mode that needs them.
- **[catalog/](catalog/CATALOG.md)** — defect shapes, one file per
  shape, consulted BY ID when a lens names one in `refines:`. Open it directly
  (`catalog/U-07-*.md`) or search across them rather than reading the index
  first: `grep -rl "abort" catalog/`.
- **[items/](items/ITEMS.md)** — checklist lines that only apply to some
  projects. Each declares the [traits](references/traits.md) it needs, the
  project declares the traits it has, and `loop.py brief` merges what matches
  and **names what it held back**. A project extends the vocabulary with
  `local traits:` and its own `.claude/loop/items/`.
- **[references/](references/REFERENCES.md)** —
  [model.md](references/model.md) (terms),
  [rule-zero.md](references/rule-zero.md),
  [review.md](references/review.md) (the seven questions — the whole file is the
  prompt `loop.py review` prints; the reasoning behind it is
  [review-why.md](references/review-why.md)).
- **[evals/](evals/EVALS.md)** — scenarios that check the skill itself. Run them
  after changing this file or `methods/`; `loop.py selftest` covers the
  mechanical half first.
- **`scripts/loop.py`** — `init`, `status`, `next`, `brief`, `lint`, `stale`,
  `catalog`, `review`, `yield`, `selftest`. **Every one reports facts; only the
  round cap decides.** And **none of them guesses at prose**: every value comes
  from a place a schema declares — a frontmatter key, a fenced `gate` block, a
  file name held in a constant. A check that needed to interpret a sentence was
  removed rather than approximated.

**Refer to a step by NAME, never by number** — the numbering here moves whenever
a step is added, so cite the bold name.
