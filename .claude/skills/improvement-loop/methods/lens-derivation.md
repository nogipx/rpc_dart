# How to build a lens set, and how to pick a lens

> [Methods](METHODS.md) · `lenses` mode, and the **Target** step of an ordinary
> round · the shapes to instantiate from:
> [catalog/](../catalog/CATALOG.md) · the field schema:
> [specs/lens.md](../specs/lens.md)

The lens schema — `../specs/lens.md`. The universal shapes —
`../catalog/CATALOG.md`. Maintaining an existing set — `curate.md`.

## Sources, in order

1. **Owner decisions** — leads with a filled-in `## Owner decision` and status
   `awaiting owner`. `loop.py status` shows them; they come before any lens.
2. **The project's set** — `.claude/loop/lenses/`. Specific, with real detectors
   and real numbers.
3. **The universal catalog** — `../catalog/`. Shapes that hold in any code.
   **Not applied directly**: they have no detector for this code.
4. **Deriving new ones** — if the project has no set, `lenses` mode builds a
   starter. Everything derived is marked as a hypothesis.

## Pick a lens from the data, not from a feeling

`loop.py next` implements these rules and prints them as a ranked SHORTLIST.
**The script ranks; the agent chooses.** They are written down here so that the
choice is deliberate and lands in the round's `## Target` with a reason —
including when it is the top entry.

One printed answer made the loop's judgement invisible: over rounds 234-238 it
named a never-applied lens five times running, every answer defensible on its
own, and nothing in the output showed what was being passed over. Ranking is
still computed rather than remembered, which is what keeps an unattended run
auditable; only the pick moved.

The tiers, in the order `next` emits them. "The least-explored surface" is
measured by the `applied:` key:

0. **A CONTINUATION lead** — `status: open` with `continuation: yes`, i.e. work
   a round started and stopped for scope. It comes before any lens, because a
   loop that opens a new thread every round never finishes one: measured over
   rounds 234-238, five rounds took five different never-applied lenses while a
   migration opened at 234 sat at 27 unfinished files. Blocked leads do NOT
   carry the flag and do not compete here — see
   [specs/backlog-item.md](../specs/backlog-item.md).
1. `derived` with `applied: []` — before any lens already applied: a hypothesis
   nobody has paid for yet.
2. Among the rest, the line order in `LENSES.md`; that is the rank, and `curate`
   sets it.
3. `swept here` is taken only with a reason: `loop.py stale` showed changes
   along its paths, or `verify` mode asked for it. Re-checking what is swept by
   default wastes a round.
4. `retracted` is not taken.
5. If the set is exhausted and fresh — an open lead as a re-measurement (U-21);
   with none of those either, `status` says "Stop: YES".

Within a lens, the target is the instance from the detector's list that is
reachable from outside, ahead of one reachable only from your own code.

## Deriving a set for an unfamiliar project

This is analysis, not guesswork from the repository's name. The result is a
starter set of hypotheses, each with status `derived`.

1. **A map of the promises.** What the project guarantees to the outside and
   what it pays for a breach: ordering, delivery, integrity, isolation, response
   time, ceilings. The damage classes come from here, not from a generic list.
2. **Enumerate the surfaces:**
   - trust boundaries — what in the input someone else controls;
   - resource accounting — what is counted, where it is released, and what the
     error path does;
   - lifecycles — what can be called twice, what survives a restart;
   - shared code with different consumers — one producer, many delivery shapes;
   - dependency extension points — callbacks and setters of a foreign API;
   - layers outside the main language, and targets outside the main gate.
3. **Run the catalog for applicability.** `loop.py catalog` gives the shape list
   for the enabled packs and the damage-class vocabulary; a shape from a
   disabled pack is not offered — if it is clearly needed, enable the pack in
   `config.md` first. For each shape: its `applies` against the project's
   properties. Instantiate an applicable one — rewrite the detector in terms of
   this code, with real symbols, paths and globs in `paths:`, and set
   `refines: <U-ID>`. Where the instance list can be produced programmatically,
   the detector is a script (`detector-script: …`; ready-made ones are in
   `packs/*/detectors/`). **A shape that is not instantiated does not enter the
   set.**
4. **Add the purely local shapes** the catalog does not have: they are the set's
   main value.
5. **Rank by «damage x reachability»**, not by elegance. A defect reachable only
   from the library's own code ranks below one reachable from outside. The rank
   is the line order in `LENSES.md`.
6. **Write it down** — one file per lens plus a line in `LENSES.md` — with
   status `derived`, `applied: []`, and an explicit note in `LOOP.md` that no
   round has checked the set. `loop.py lint` must be green by the end of the
   mode.

**A universal lens copied without a detector is useless.** A set with no
concrete symbols, paths and commands is a list of good intentions that a round
searches blindly.

## When to redo the derivation

A new capability in the project — a new dependency, a new layer, a new build
target — is a reason to redo the derivation: the lens set ages along with the
code. The
signal is the "Directories with no lens at all" section of `loop.py stale`.
