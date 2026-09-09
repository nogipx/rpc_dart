---
applies: there are networks, channels, queues or streams with backpressure; two sides configured independently; limits on bytes in flight; someone else controls the input
damage classes: DoS, wrong status, broken ordering, broken delivery, wedged stream
shapes: U-07, U-08, U-09, U-10, U-11, U-13, U-16
contains: measure.md, canary.md, tests.md, review.md
---

# async-io — two sides, a channel, limits, waits

Everything here was paid for by rounds on a transport library; the numbers in
the stories are the size of the trap, not a tie to that code.
