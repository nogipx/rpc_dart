---
status: open
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/data/**, packages/notify/**, packages/blob/**]
probe: —
reason: the lens set was derived from the round history, which is almost entirely about core and the transports; the data, notify and blob layers never entered it
---

# B-10 — Three layers of the project have no lens at all

`loop.py stale` counts lens path coverage against the tracked files and names
the directories no detector looks at:

    packages/data/     108 files
    packages/blob/      76 files
    packages/notify/    50 files

This is not a code defect but a hole in the lens set: 234 files the loop has
never searched. It closes in `lenses` mode — redo the "enumerate the surfaces"
step over those three packages and instantiate the applicable catalog shapes,
rather than carrying the transport lenses across mechanically.

Check the `crdt` pack's applicability separately: `packages/data` may fit
`applies: several replicas, coordination-free merge, offline-first` — in which
case it joins the enabled packs.

## Owner decision

—
