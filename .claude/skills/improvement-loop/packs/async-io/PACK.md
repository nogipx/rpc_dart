---
applies: there are networks, channels, queues or streams with backpressure; two sides configured independently; limits on bytes in flight; someone else controls the input
damage classes: DoS, wrong status, broken ordering, broken delivery, wedged stream
shapes: U-07, U-08, U-09, U-10, U-11, U-13, U-16
contains: measure.md, canary.md, tests.md, review.md
---

# async-io — two sides, a channel, limits, waits

> [Packs](../PACKS.md) · schema: [specs/pack.md](../../specs/pack.md) · its
> items extend [measurement.md](../../methods/measurement.md),
> [canary.md](../../methods/canary.md),
> [tests.md](../../methods/tests.md) and
> [review.md](../../references/review.md)

Everything here was paid for by rounds on a transport library; the numbers in
the stories are the size of the trap, not a tie to that code.

## Contains

`loop.py` appends each of these to its universal counterpart when the pack is
enabled; none is read on its own.

- [measure.md](measure.md) — added to the measurement checklist
- [canary.md](canary.md) — added to the canary protocol
- [tests.md](tests.md) — added to the regression-test rules
- [review.md](review.md) — added to the verdict check's questions
