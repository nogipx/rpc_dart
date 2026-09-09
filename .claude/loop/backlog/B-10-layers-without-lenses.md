---
status: open
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/data/**, packages/notify/**, packages/blob/**]
probe: —
reason: deferred by owner (round 223) — not until core and transport have nothing left; the lens set was derived from a round history that is almost entirely core and transports
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

**Deferred to the far future.** (Asked and answered in round 223.)

Not to be taken up while `core` and `transport` still have work. Those are the
packages that carry the project, and the loop's attention belongs there; 234
unexamined files in `data`, `notify` and `blob` are a real hole, but a
lower-priority one than anything outstanding in the two layers everything else
depends on.

**Do not rank this into a round's target on the strength of its size.** It is
the largest unexamined surface in the repository and will keep looking like the
obvious next thing; it is not, until the core and transport backlog is empty.
`loop.py stale` will keep naming the three directories — that is expected, and
not a signal to act.
