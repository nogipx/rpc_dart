---
round: 333-334 — where it was paid for; the owner named it after 334
class: process
cost: two rounds and an owner correction. 333 measured 58 interpolating log sites in core and guarded 16; 334 guarded 24 more and reported "~20 sites remain" as ordinary remaining work. The real surface was ~200 across core and the four transports, and the owner had asked about the class, not the sample
paths: [—]
commit: 355f773c
status: active
---

# L-12 — sweep the class, not the sample

The owner asked why log strings are built when the level discards them. Round
333 counted **58 interpolating sites in core**, guarded the **16** on the unary
per-call path, measured the win and filed the rest under "Not fixed". Round 334
guarded ~24 more and filed "~20 remain". Both records were true and both were
subsets. The actual surface — every `internal`/`trace`/`debug` call across core
and the four transports — is about **200 sites**.

Two rounds of honest numbers still added up to an under-delivery, because the
scope was never stated and kept shrinking to whatever had been done.

## The rule

**Count the class before fixing any of it, and put the count in `## Target`.**
Then either fix all of it, or state the scope up front with the reason and the
number. "Remaining work" written at the END of a round is a decision the owner
never got to make.

Minimal and complete are different axes: minimal in DEPTH (one mechanism, at the
point that renders the wrong verdict), complete in BREADTH (every instance of
that mechanism). Round 333 was right to fix only the guard idiom and wrong to
fix only the unary path.

## What the count would have shown here

Taking it properly, on the tree after 334, splits the surface in a way that
changes the work:

```
core        _logger.internal(...)      non-nullable, LogScope.noop default
                                       -> the argument ALWAYS evaluates
transports  _logger?.internal(...)     nullable
                                       -> `?.` short-circuits, so with no
                                          logger attached nothing is built
```

The two halves are not the same defect, and a count taken first would have said
so before either round chose a subset.

## Applied, round 337

The full sweep: 158 sites, counted and put in `## Target` before the first edit.
The count paid for itself twice over — it showed that the two halves are not the
same defect (nullable vs not), that three transports were not in the class at
all, and that **unary is the CHEAPEST of the four call shapes by a factor of
seven**, which is the fact that made 333's and 334's "nearly done" wrong.

## Where it does NOT apply

A round that finds ONE instance of a shape and fixes it is not under-delivering
— the sweep is what tells you whether there are others. The failure is knowing
the count and fixing part of it silently.
