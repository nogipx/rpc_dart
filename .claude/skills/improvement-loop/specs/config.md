# Schema: the project settings

> [Schemas](SPECS.md) · written by [methods/setup.md](../methods/setup.md) ·
> the gate block must satisfy
> [references/rule-zero.md](../references/rule-zero.md) · the vocabulary
> `traits:` draws on: [references/traits.md](../references/traits.md)

Path: `.claude/loop/config.md`. The only loop file written by hand, and rarely.
The machine-read places — `unattended:`, `traits:`, `local traits:`,
`damage classes:`, `commit language:`, the ```gate and ```after-commit blocks,
and the three budget lines — use an exact format; the rest is prose for the
agent.

The mandatory sections, in this order:

- **Mode** — the line `unattended: yes` or `unattended: no`. It decides whether
  rule zero applies in full. With `no`, interactivity is allowed, but the
  requirement to read and edit files with Read/Edit/Write stands.
- **Traits** — the line `traits: dart, dart2js, two-sided-protocol`: what this
  project IS. Every file in `items/` declares `needs:`, and
  `loop.py brief` merges the ones whose needs the traits cover. Matched by set
  membership on identifiers — never by meaning.

  **The vocabulary is open and a project extends it.** Names from
  [references/traits.md](../references/traits.md) go in `traits:`; names only
  this repository needs go in `local traits: grpc-wire-compat, wasm-bridge`,
  together with items that ask for them in `.claude/loop/items/`. `lint`
  refuses a registry name in `local traits:` and a non-registry name in
  `traits:` — that one rule is the whole difference between inventing a trait
  and mistyping one.

  A trait nobody's item needs is reported as buying nothing. That is
  information, not an error: it marks a property of the project whose knowledge
  has not been written down.

  This replaced `packs: core, async-io, dart`, which switched bundles on and
  off. A bundle mixed a language, an architecture and a deployment shape as
  though they were one axis; enabling `dart` for a VM-only project handed it the
  dart2js rules, and there was no way to take one item without the rest. `lint`
  refuses a `packs:` line so the old form cannot sit there looking effective.

  The optional `damage classes:` line adds project nouns to the vocabulary
  offered for a lens's `breaks:`. **Nothing reads them mechanically** — matching
  a vocabulary against free text would be a guess about prose.
  A round whose target is the shape of the code rather than a defect in it — a
  doc audit, a public-surface sweep — is an ordinary round taking an ordinary
  shape. It records `bench: none — <reason>` like any round whose evidence is
  not a quantity. There is no setting for it.
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
  at a failing witness), `round cap: N`. `loop.py next` prints all three at the
  start of the round. The first two are **stopping limits the round applies to
  itself**: past them the honest verdict is INCONCLUSIVE, and the round says in
  `## Before` what was tried. Nothing counts them for you — a `budget:` key
  self-reported from memory was dropped as evidence nobody could check. `round
  cap: N` is different: it is the one number the script enforces, because an
  unattended agent asked "should we continue?" always says yes.
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
