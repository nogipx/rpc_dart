# Lay the loop out in another repository

The skill is the process and the specification; everything bound to a repository
lives in `.claude/loop/`. The file schemas are in `../specs/`; here is only what
has to be decided at setup, and in what order.

## Order

1. **`python3 <skill>/scripts/loop.py init`** from the repository root. It
   creates `LOOP.md`, a `config.md` with the mandatory sections and hints, and
   six directories with empty indexes. If `.claude/loop/` already exists it
   refuses: no laying out on top of data. A `.claude/loop.md` may sit next to
   it — that is the prompt override for Claude Code's bundled `/loop` skill and
   has nothing to do with the loop data; do not create it by accident.
2. **Fill in `config.md`** per `../specs/config.md`. Everything listed there is
   decided by the owner or by an agent that has read the repository; the
   machine-read places (`unattended:`, `packs:`, the `gate` and `after-commit`
   blocks, the round budget) use the exact format. Do not duplicate the
   repository's `CLAUDE.md`: link to it. **Packs** — by the `applies:` of each
   `packs/*/PACK.md` against what the repository actually has: the language, two
   sides and limits, screens, replicas, a service. Enable them by properties of
   the code, not by the project's name.
3. **Permissions** (when `unattended: yes`). In `.claude/settings.json`, under
   `permissions.allow`, one prefix rule per toolchain and gate command —
   `Bash(dart test:*)`, `Bash(dart analyze:*)` — plus a rule for the script with
   an absolute path:
   `Bash(python3 /.../improvement-loop/scripts/loop.py:*)`. If the file does not
   exist, create it; if it does, append to the array without deleting anything.
   `loop.py lint` will say which gate command is not covered. The skill expects
   itself at `.claude/skills/improvement-loop` or
   `~/.claude/skills/improvement-loop` — that is how the status block in
   SKILL.md finds it; fix that line for another path.
4. **History.** If there were earlier rounds whose records cannot be recovered,
   say so in `LOOP.md` ("What to trust with care") and start numbering at `001`
   rather than inventing a past. References to unrecovered rounds stay as bare
   numbers with the marker.
5. **The first seeding of the backlog and the negatives** — from what is already
   known about the project. Every record not re-measured in this session gets
   `round: — (not re-measured)` and `commit: <current HEAD>`: from that moment
   `stale` computes the ageing. Tell them apart by "is there work to do": in the
   backlog there is, in the negatives there is not.
6. **The first lens set** — `lenses` mode per `lens-derivation.md`. Every record
   `derived`, `applied: []`; a note in `LOOP.md` that no round has checked the
   set.
7. **`loop.py lint`** green. A commit marked `setup` in the body, with no round
   file.
8. **Scheduled runs** (Claude Code): `/loop /improvement-loop` with no interval —
   Claude picks the pause between rounds from what it saw; or
   `/loop 45m /improvement-loop` with an interval longer than a typical round. A
   round cancels the job itself on "Stop: YES". The alternative is `/goal`: keep
   working until `loop.py status` says "Stop: YES".

## Checking the setup

The setup succeeded when, from a standing start, you can:

1. have `loop.py status` name the next round's number — `001`;
2. name the gate command without looking into history: it is in the `gate`
   block;
3. name the lens the next round would take, with its detector and paths —
   concretely, down to the symbols;
4. name at least one negative result that must not be re-run.

If the fourth is empty, the loop has not started — that is fine, but write it in
`LOOP.md`. If the third is empty, the setup is not finished.
