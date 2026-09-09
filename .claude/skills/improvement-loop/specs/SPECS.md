# Schemas for the loop's files

What every file in `.claude/loop/` consists of. One schema per file, like
everything else in this skill. The schemas are not read by the agent alone:
`scripts/loop.py lint` checks the mandatory fields, names and links against
exactly these schemas, so the field format is part of the contract rather than
decoration.

- **[round.md](round.md)** — the round file, `rounds/NNN-slug.md`. Also the only
  home of the round record, the verdicts, and what each of them changes.
- **[lens.md](lens.md)** — a lens, `lenses/<PREFIX>-NN-slug.md`
- **[backlog-item.md](backlog-item.md)** — a lead, `backlog/B-NN-slug.md`
- **[checked-item.md](checked-item.md)** — a negative, `checked/C-NN-slug.md`
- **[probe.md](probe.md)** — a bench, `probes/P-NN-slug.md`
- **[lesson.md](lesson.md)** — a lesson, `lessons/L-NN-slug.md`
- **[index.md](index.md)** — a directory index, `<DIR>/<DIR>.md`
- **[map.md](map.md)** — the data map, `LOOP.md`
- **[config.md](config.md)** — the project's settings, `config.md`
- **[pack.md](pack.md)** — a knowledge pack, `packs/<name>/` in the skill or in
  the project

## Rules common to every schema

- **One file per entity.** One big file for everything will not do: everything
  gets edited in one place, everything conflicts, and nothing can be found.
- **The identifier in the file name and in the heading**, fixed width (`RPC-08`,
  not `RPC-8`; rounds are `012`): the name gives sorting in `ls`, the heading
  gives `grep -rn "RPC-08"`, which catches both the record and every reference
  to it.
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
