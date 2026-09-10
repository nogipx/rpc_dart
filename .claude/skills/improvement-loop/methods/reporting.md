# How to report

> [Methods](METHODS.md) · at the **Gate** step, with the record · the record's
> own schema is [specs/round.md](../specs/round.md)

The round record's schema is `../specs/round.md`, and it is one schema for all
three audiences: the round file, the commit body, the chat report. What is not a
loop file lives here.

**The frontmatter goes into the file only.** Its values travel to the commit and
the chat as prose, not as a `---` block: nobody reads YAML in a commit body, and
in chat it is noise.

## The chat report — SHORT when nobody is watching

**With `unattended: yes`, the chat report is a handful of lines, not the record
again.** The round file and the commit body already hold the measurement, the
mechanism, the canary text and what was left undone; a scheduled run has nobody
reading chat as it happens, so restating all of it there costs tokens on every
round and is read by no one. What the report is FOR in that mode is letting
someone scanning later decide whether to open the record:

    Round N — VERDICT — topic
    the one number that carries the finding (before -> after)
    what shipped, or why nothing did
    the commit sha, and anything that needs the owner

Four lines is a normal report. A round that ends DEFERRED or INCONCLUSIVE, or
that wants an owner decision, is the one case worth a paragraph — because that
is the round whose next step depends on a human.

**With `unattended: no` the fuller shape below applies**: somebody is at the
keyboard, following along, and the detail is the point.

Measured on this loop's own output: rounds 240-249 averaged well over 200 words
of chat each, restating records that were already committed and linted. None of
it was read while the loop ran.

## The commit

**ONE commit per round, and it is the last thing the round does.** Everything
the round produced rides in it: the round file, the lens's `applied:`, a new
bench, a new or edited lead, an owner decision captured mid-round, a correction
to a note the round itself wrote ten minutes earlier. A round does not commit as
it goes.

Measured on round 247, which shipped five separate `docs(loop)` commits — the
record, the decisions, a status fix, a note, and a correction to that note. Four
of them were the same round still thinking. The journal reads as one commit per
round or it stops being a journal, and a reader diffing "what did round 247
learn" should get one diff.

Two consequences worth naming:

- **A correction to something uncommitted is an edit, not a commit.** Fix the
  file and let the single commit carry the final state.
- **A correction to something already committed in THIS round is an amend.**
  `git commit --amend -F <file>` — same round, same commit.

`loop.py lint` ENFORCES this: **any two consecutive commits that touch nothing
outside `.claude/loop/` are an error**, whatever files each one touches, so the
gate cannot be green until they are one.

Both strictnesses were argued down from weaker versions, by the owner, after
watching them fail:

- it was a **warning** first, and that version fired twice on consecutive
  rounds, was read both times and reasoned past both times — enforcement by
  advisory text depends on exactly the judgement that already failed;
- it then required the two commits to edit the **same record**, on the
  reasoning that two different rounds each committing once look identical from
  outside. Wrong from the place that matters: a reader of the journal sees two
  commits where one piece of work happened, and which files each touched does
  not change that.

**READ THE COMMIT BACK. Every time.** `git log --oneline -3` plus
`git status --short`, and for anything with punctuation in it,
`git log -1 --format=%B`. A commit is the round's only durable output and there
are four ways it silently is not what you meant:

- **the message was mangled** — backticks in a shell argument get SUBSTITUTED
  (L-03), so `read \`owedConn\` out of ...` committed as `read  out of ...` and
  the failed substitution printed to stderr while the commit succeeded anyway;
- **the commit did not happen** — an `&&` chain whose earlier link failed, or
  nothing staged;
- **it took more than intended** — a `git add` broader than the round;
- **the amend hit the wrong commit**, or amended when a new commit was meant.

Reporting "committed as <sha>" without having read it back is a claim about
work rather than a record of it. This was written after an owner had to point
out, twice, that what was reported as done was not what had landed.

**The language is the `commit language:` line in `config.md`, English by
default** (`loop.py next` prints it). It applies to the commit's subject and
body, not to the loop data: if the records are kept in another language, the
body restates their sections in the commit language rather than copying them.

The subject conventions are in the repository's `CLAUDE.md` (type, scope, one
package per commit, imperative, style). The body starts with the line
`Round N — <verdict> — <topic>`: `git log --grep "Round N "` finds the
commit by it, and `loop.py lint` checks that a round with `commit: yes` has one.
The body carries what the diff does not:

- the measurement: the before and after numbers, with the probe's name;
- the mechanism: why it happened;
- the canary: what was switched off, and the real text the witness failed with;
- the gate: what was run;
- not fixed: what is left, and for what reason.

The round file and the edits to the lens, the leads, the negatives and the
indexes ride in the same commit as the fix: the round is visible in one diff.

## Comments beside the code

What earns a place at the point of a subtle fix: the mechanism in one sentence,
the before/after numbers, and the trap that would otherwise be rediscovered.
What does not: restating what the code already says, the story of the search, a
repeat of a justification already written next door, and the same measurement in
three files.

> **The long version lives in the commit and in the round file; the comment gets
> the compressed one.**

The owner's preferences on documentation volume are in the project's
`config.md`.

## The chat report

**The language is the `reply language:` line in `config.md`, English by
default** (`loop.py next` prints it, next to `commit language:`). A standing
instruction from the user wins over it; say which you followed if they differ.

The same sections as the round file, plus two lines: the output of
`loop.py lint`, and "next round: the target from `loop.py next`", or
"Stop: YES — reason". If the call came from `/loop` and it is a stop, say the
job has been cancelled. Do not dress anything up: if the gate failed, say so
with the output; if a step was skipped, say it was skipped. A clean round is
reported as clean, listing the negative results; INCONCLUSIVE is reported as
INCONCLUSIVE, listing what was tried on the bench.

## What is not allowed

- **Correcting your own record in chat only, and not in the source**, when
  something was overstated earlier. Nobody believes prose beside code after the
  fact, and it outlives the chat.
- **Leaving the owner's decisions to the owner**: default policy values, process
  changes, anything that trades safety for a legitimate scenario. Report with a
  recommendation rather than acting: a lead with status `awaiting owner` and an
  empty `## Owner decision`. What holds permanently goes into `config.md`.
