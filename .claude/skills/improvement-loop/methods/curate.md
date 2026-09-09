# curate mode: data maintenance

> [Methods](METHODS.md) · `curate` mode, once every ten rounds · what a promoted
> lesson becomes: a [catalog](../catalog/CATALOG.md) shape or a
> [pack](../packs/PACKS.md) item · the lesson schema:
> [specs/lesson.md](../specs/lesson.md)

Once every ten rounds, or on request. It measures nothing and fixes nothing: it
only puts the data in order so the next round chooses on correct information. A
separate commit marked `curate` in the body, with no round file.

## Order

1. `loop.py lint` — red is fixed first, those are bookkeeping defects.
2. `loop.py stale` — read what has aged:
   - a sweep (`swept here`) with changes along its paths — do not change the
     status, raise the lens in the rank instead: the next round takes it as a
     re-measurement;
   - a negative with changes — mark its index line `(stale, sha)`; it must not
     be deleted, and re-measuring it is a round's target;
   - a lead with changes — the same.
3. **Lens rank.** A lens that produced no finding three rounds running goes
   down. It must not be deleted: no findings is a result too, and a deleted lens
   will be reinvented. A lens with `applied: []` for more than ten rounds is
   either raised or written into `LOOP.md` with the reason nobody takes it.
4. **Duplicates.** Two lenses with one shape — the younger gets `refines:` the
   older and status `retracted` with reason "duplicate". Two leads about one
   mechanism merge into the older, and the younger closes with a link.
5. **Lead rank.** The order in `BACKLOG.md`: owner decisions first, then by
   damage class, then by the age of the number.
6. **Benches.** A `valid` one that `stale` reports as STALE gets status
   `stale (sha)`: the next round on those paths must repeat its control before
   reusing it. A `broken` one older than ten rounds with no replacement stays —
   that is a negative too.
7. **Lessons.** Re-read each `active` one against the code it describes; retire
   what no longer holds. **Do not promote them into `methods/` or `catalog/`** —
   that conveyor existed for 39 rounds and moved exactly zero lessons, while
   every promotion would have GROWN a skill whose binding constraint is already
   the attention it costs to read. Lessons are a permanent project-local layer.
   If two say one thing, merge into the older.
8. **The catalog.** A shape instantiated and confirmed in this project but
   missing from `../catalog/` is a candidate for it, by the same test: does it
   hold outside this code?
9. `loop.py lint` again, then commit.

## What curate does not do

- It does not change statuses that require measurement: `swept`, `confirmed`,
  `closed`.
- It does not rewrite numbers. A number that looks wrong is a target for
  `verify`.
- It does not validate benches: only a round with a control sets `valid`.
- It does not touch `config.md`: the settings are the owner's decision.
