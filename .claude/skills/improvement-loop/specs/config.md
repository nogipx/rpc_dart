# Schema: the project settings

> [Schemas](SPECS.md) · written by [methods/setup.md](../methods/setup.md) ·
> the gate block must satisfy
> [references/rule-zero.md](../references/rule-zero.md) · the packs it enables:
> [packs/](../packs/PACKS.md)

Path: `.claude/loop/config.md`. The only loop file written by hand, and rarely.
The machine-read places — `unattended:`, `packs:`, `damage classes:`,
`commit language:`, the ```gate and ```after-commit blocks, and the three budget
lines — use an exact format; the rest is prose for the agent.

The mandatory sections, in this order:

- **Mode** — the line `unattended: yes` or `unattended: no`. It decides whether
  rule zero applies in full. With `no`, interactivity is allowed, but the
  requirement to read and edit files with Read/Edit/Write stands.
- **Packs** — the line `packs: core, async-io, dart` — which knowledge packs are
  enabled (the skill's `packs/` or `.claude/loop/packs/`); `core` always is. The
  optional `damage classes:` line adds project classes to the packs'; `lint`
  checks the lenses' `breaks:` against the union.
- **Language** — two optional lines, each **English** without it:
  `commit language: <language>` governs the round commit's subject and body,
  and `reply language: <language>` governs the round report in chat. They are
  separate on purpose: writing to a repository and talking to its owner are
  different audiences, and the common case is an English commit reported in the
  owner's language. Neither governs the loop data, which keeps its own
  language; where they differ, the commit body and the report restate the
  record's sections rather than copying them. `loop.py next` prints both values
  so a round does not learn them at the last moment.

  A standing instruction from the user outranks `reply language:` — the setting
  is the project's default, not a licence to answer in a language the person
  asking has told you not to use. When the two disagree, follow the user and
  say which was followed.
- **Toolchain** — what runs the build and the tests, including wrappers for the
  pinned SDK version. Plus the known launch traps: commands that open an
  interactive picker, and their safe forms.
- **Gate** — the exact sequence before a commit, including dependent packages
  and targets other than the main one. The gate is a sequence, not a set: order
  and completeness matter more than convenience. The commands go in a block
  tagged `gate`, one per line, exactly as they are run:

  ````
  ```gate
  dart analyze --fatal-infos
  dart test
  ```
  ````

  This block is read by `lint` (coverage by `permissions.allow` rules when
  `unattended: yes`) and by the agent at the **Gate** step.
- **Probes** — where they go and why: import resolution, exclusion from
  analysis, gitignore.
- **After the commit** — the ```after-commit block: commands for an unattended
  run after a successful round commit (push, notification). Covered by
  `permissions.allow` like the gate; an empty block means nothing.
- **Round budget** — three lines: `probes: N` (how many times the bench may be
  rebuilt before the verdict is INCONCLUSIVE), `canaries: N` (how many attempts
  at a failing witness), `round cap: N`. The round keeps the numerators in its
  `budget:` key; `lint` reconciles the denominators with these lines and does
  not let an overrun pass under a FIXED or CLEAN verdict.
- **Targets nobody runs** — another compiler, the native layer, devices,
  generators, licence linters. Each with its command and what it finds beyond
  the main gate.
- **Severity bar** — which damage classes are worth a round right now.
- **Out of scope** — explicitly: what the loop is not for.
- **Standing owner requirements** — what holds in every round and is not about
  any single finding. Decisions on individual findings live in `backlog/`, in
  the `## Owner decision` section.
- **Known flakes** — by name, so a failure is not written off as "probably a
  flake".

**Do not duplicate the repository's `CLAUDE.md`**: package layout, commit
conventions, style. Link to it rather than copying — stale prose is a defect.

**Permissions do not live here** but in `.claude/settings.json`
(`permissions.allow`): rules like `Bash(dart test:*)` for every toolchain and
gate command, plus
`Bash(python3 <absolute path to the skill>/scripts/loop.py:*)`. `setup` mode
writes them and `lint` checks the gate is covered.
