# How to report

The round record's schema is `../specs/round.md`, and it is one schema for all
three audiences: the round file, the commit body, the chat report. What is not a
loop file lives here.

**The frontmatter goes into the file only.** Its values travel to the commit and
the chat as prose, not as a `---` block: nobody reads YAML in a commit body, and
in chat it is noise.

## The commit

**The language is the `commit language:` line in `config.md`, English by
default** (`loop.py next` prints it). It applies to the commit's subject and
body, not to the loop data: if the records are kept in another language, the
body restates their sections in the commit language rather than copying them.

The subject conventions are in the repository's `CLAUDE.md` (type, scope, one
package per commit, imperative, style). The body starts with the line
`Round NNN — <verdict> — <topic>`: `git log --grep "Round NNN "` finds the
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
