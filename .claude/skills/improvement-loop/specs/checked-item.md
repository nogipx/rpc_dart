# Schema: a negative

Path: `.claude/loop/checked/C-N-slug.md`. Plus a line in `checked/CHECKED.md`.

A negative is an answered question: measured, nothing broken, nothing to do. It
is a separate entity rather than a kind of lead: confusing them means keeping
something already closed on the to-do list.

````
---
round: N
commit: <the HEAD sha at the moment of measurement>
paths: [<globs of the code that is covered>]
scope: [<which packages or subsystems are covered>]
---

# C-N — <what was checked>

<what exactly was measured>

```
<numbers>
```

## Control

Which control confirmed the bench could have shown the defect.
````

`stale` computes the ageing from `paths`.

**A negative without a control is not a negative but hope.** Without a control
there is no telling whether the probe could have shown anything at all: a bench
that fails to reach the required regime reports "clean" on broken code too. So
`## Control` is mandatory, and a round with no valid control is INCONCLUSIVE,
not CLEAN.

**A sweep by a lens detector is not written here** — its home is the
`swept here` status on the lens itself (the one-home rule). Only what is not
tied to a shape belongs here.

**A negative goes stale** along with the code: it is true for what existed at
the sha of the measurement. When new code appears along its paths,
`loop.py stale` will name it.
