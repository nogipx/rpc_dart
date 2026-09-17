---
round: 380 — where it was paid for
class: process
cost: a shipped default was one round away from being weakened fivefold. The owner decided B-47 on a sentence round 366 wrote — "the park buys nothing that can be named" — and 380 measured before carrying it out: the window bounds a burst 156.25 MiB -> 4.06 MiB, and the decided fix would have produced 19.95 MiB
paths: [—]
commit: 6a3cb2c1
status: active
---

# L-13 — a decision inherits the sentence it was taken on

An owner decision is evidence about what the owner WANTS. It is not evidence
about the code — it inherits whatever the round that framed the question got
right or wrong, and it launders a claim into an instruction along the way.

Round 366 wrote, in `## Not fixed`, that a parked sender "buys nothing that can
be named". That sentence became B-47, B-47 became a question, the question got
an answer, and the answer arrived at round 380 as a task: derive
`initialSendWindowBytes` from `maxMessageSize`. Nothing in that chain re-checked
the sentence, and by then it read as settled — it had an owner's decision on top
of it.

It was wrong. Measured over a real socket at 50 ms RTT:

```
policy                            frames      MiB
no initial window                  40000   156.25
64 KiB (shipped)                    1039     4.06
= maxMessageSize (16 MiB)           5108    19.95
```

Both halves of the contradiction were true of different things, which is how it
survived: for ONE message larger than the window the park really does buy
nothing, because the gate admits on `credit > 0` rather than on fit. Round 366
measured 2, 3 and 8 frames — it never ran a flood, which is the regime the field
exists for.

> **Before carrying out a decision, re-measure the sentence it was taken on.**
> Not the decision — the claim underneath it. The round that executes is the
> last point where a wrong premise is still cheap.

Two things made this one findable, and both are ordinary:

- **The field's own doc comment contradicted the claim, with numbers.** The
  standing rule is that a measured table inside a comment is somebody else's run
  rather than evidence — which is true, and which is not permission to ignore
  it. A contradiction between a comment and a round is a reason to measure, and
  here the comment was right to within 0.01 MiB.
- **The arm that would have been the fix was its own control.** Running it
  beside the others is what turned "this may be wrong" into "this makes it five
  times worse", and it cost one extra line in the probe.

Reported before acting rather than after, which is the only part of this that is
not luck: the verdict was RETRACTED and the owner's instruction was left
undone, with the numbers and the reason in the record.

See also [L-05](L-05-green-locally-is-not-green-clean.md) — an ablation proves
sensitivity, not portability. Same family: a result is about exactly what was
varied, and a sentence generalising it is a separate claim.
