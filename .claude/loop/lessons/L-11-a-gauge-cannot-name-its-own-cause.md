---
round: 321 — where it was paid for
class: metric
cost: three rounds on one assertion, two CI-only failures, both reading `Actual: <0>`
paths: [packages/**/test/**]
commit: 0c053c6b
status: active
---

# L-11 — Assert an event at the peer, never by polling a gauge

A guard that the aborted requests reached the server polled `pendingRequests`
and asserted it rose; it failed twice on CI as `Actual: <0>`, and each round
fixed the QUESTION it asked the gauge — a simultaneous count, then a peak, then
a peak over an earlier window — because `0` reads identically whether nothing
arrived or the sampler never looked. Measured in round 321, no shape was ever
losing a race: the requests sit in the map for 2009 ms and a 5 ms sampler hits
401 times out of 1191, so all three were correct locally and mute about CI.

**A gauge that rises and falls can only be sampled, and a sample cannot
distinguish "it did not happen" from "I did not look".** Assert the EVENT
instead, where it is delivered: the status the peer receives, a completer, a
counter the code under test increments monotonically. Round 321's replacement
has three outcomes — a status line, `closed`, `STILL DRAINING` — and each names
which thing broke, which is the property the number never had.

The cheap way to see this before shipping a guard: run the old and the new
observable on the SAME ablation. Round 321 did, and the polled one reproduced
the CI message character for character where the edge-triggered one said
`closed`.

Settling is the exception and stays safe: polling a gauge until it reaches zero
asserts a state that persists, so a late look still sees it.
