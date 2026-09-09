# Schemas for the loop's files

What every file in `.claude/loop/` consists of. One schema per file, like
everything else in this skill. The schemas are not read by the agent alone:
`scripts/loop.py lint` checks the mandatory fields, names and links against
exactly these schemas, so the field format is part of the contract rather than
decoration.

- **[round.md](round.md)** — the round file, `rounds/N-slug.md`. Also the only
  home of the round record, the verdicts, and what each of them changes.
- **[lens.md](lens.md)** — a lens, `lenses/<PREFIX>-N-slug.md`
- **[backlog-item.md](backlog-item.md)** — a lead, `backlog/B-N-slug.md`
- **[checked-item.md](checked-item.md)** — a negative, `checked/C-N-slug.md`
- **[probe.md](probe.md)** — a bench, `probes/P-N-slug.md`
- **[lesson.md](lesson.md)** — a lesson, `lessons/L-N-slug.md`
- **[index.md](index.md)** — a directory index, `<DIR>/<DIR>.md`
- **[map.md](map.md)** — the data map, `LOOP.md`
- **[config.md](config.md)** — the project's settings, `config.md`
- **[pack.md](pack.md)** — a knowledge pack, `packs/<name>/` in the skill or in
  the project

## Rules common to every schema

- **One file per entity.** One big file for everything will not do: everything
  gets edited in one place, everything conflicts, and nothing can be found.
- **The identifier in the file name and in the heading.** The name gives an
  anchor for `ls`, the heading gives `grep -rn "RPC-8"`, which catches both the
  record and every reference to it.

  **Numbers are not padded.** `RPC-8` and `RPC-08` are both fine, `7-slug.md`
  is a round file like any other, and nothing computes a width. What the
  padding used to buy was lexicographic `ls` order; the indexes and
  `loop.py status` are what the journal is actually read through, so the cost
  was a rule to remember for a benefit nobody used. Two consequences worth
  knowing: `ls` shows `10-` before `2-`, and `grep "B-1"` also matches `B-10`
  — use `grep -w` or the file name when a reference has to be exact.

  `loop.py` normalises a round number before comparing (`round_key`), so `007`,
  `7` and `round 7` are one round and a cross-reference cannot silently point
  at nothing. Verified by canary: with the normaliser reduced to identity,
  `applied: [007]` against `7-seven.md` reports "no file" and the round's
  back-reference check fails too.

  **Padding is no longer required, not forbidden.** A journal written under the
  old rule keeps reading: `001-one.md` with an index line `[001]`, an
  `applied: [001, 002]`, a `status: confirmed (round 002)` and a
  `round: 001` all resolve. The index links are normalised for the same reason
  the file keys are — measured on a padded fixture, without that step every old
  round reported "file with no line in ROUNDS.md". The two spellings
  interoperate, so a migrating journal may simply stop padding at its next
  round and leave the old names alone.
- **An identifier never changes** once created — things refer to it. Rank and
  order live in the index.
- **The next free number is stored nowhere.** It is the maximum in the directory
  plus one, computed by `loop.py status`. A written-down number is a second home
  for a fact, and it will drift.
- **Machine fields go in the frontmatter, prose in `## Section` blocks.** The
  file starts with `---`, then `key: value` in lower case: a scalar, `[a, b]`,
  or a `- item` list below. Nothing nested. A value containing `: ` must be
  quoted, or it is not YAML. Anything longer than a line lives in a section
  under its own `##`.

  It was not always so, and the previous format is worth remembering as a
  measurement: fields were written aligned into a column (`Lens:` plus an indent
  on the continuations), and **the whole file rendered as ONE paragraph** —
  CommonMark treats an indented line after a paragraph as its continuation.
  Checked with pandoc on round 205's record: 15 fields and two matrices of
  numbers were glued into solid text with the columns interleaved. And the
  alignment was not needed by the parser either: it took the field name from the
  start of the line and accepted any indent on a continuation.
- **Links run both ways.** A round names its lens in `lens:` and its bench in
  `bench:`; a lens names its rounds in `applied:`; a lead, a negative, a bench
  and a lesson name the round that produced them in `round:`. A one-way link is
  a defect in the record, and `lint` finds it.
- **The one-home rule.** A fact lives in one place; everywhere else there is a
  link.
- **A sha wherever a fact ages.** A sweep, a negative, a lead, a bench and a
  lesson store the `HEAD` sha at the moment of measurement and the paths it
  covered; `loop.py stale` uses them to compute what has changed.
- **No tables.** A Markdown table drifts at the first edit and is unreadable in
  a terminal. A list of identical lines is edited without ceremony and found by
  grep.
- **Numbers go in ``` .** This is not decoration: rendering glues consecutive
  lines of a paragraph into one and the columns interleave. A fenced block keeps
  them both raw and rendered, and does not drift — so it closes the same hole a
  table would without breaking the rule above. `lint` warns about a multi-line
  `## Before` with no ``` .
