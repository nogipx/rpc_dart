---
file: packages/core/rpc_dart/.dart_tool/probe/b129_retry_backoff_cancel.dart
round: 521
commit: 7cdaabf6
paths: [packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart]
status: valid
---

# P-158 — does a cancel cut the retry backoff?

## Why it exists

B-129 item 13 says a cancel during backoff waits up to `maxDelay`. That is the shape
round 499 fixed in `ping()` — a wait ignoring the token it was given — so it is worth
measuring rather than assuming either way.

## The harness

A handler that always answers UNAVAILABLE, a retry interceptor with `maxAttempts: 5`
and a backoff pinned at 4 s, and a cancellation token fired at a chosen moment. The
backoff is deliberately long so that "waited it out" and "cancelled promptly" cannot
be the same number by accident.

The first attempt fails almost immediately, so a cancel at 300 ms lands squarely
inside the first backoff.

## The numbers (round 521)

```
cancel DURING the backoff     status 1 (CANCELLED)     after 2118 ms
CONTROL cancel immediately    status 1 (CANCELLED)     after 1504 ms
CONTROL no cancel at all      status 14 (UNAVAILABLE)  after 5237 ms
```

## Round 623 — the numbers above were jitter

`ExponentialBackoff` jitters by default, so each wait is uniform in (0, 4 s] and
every row is a random draw. At HEAD the same probe read `1748 / 3283 / 11442 ms`.
With a fixed backoff the cancel waited the backoff out (`3053 ms` for a cancel at
300 ms of 3 s), which round 521's "refuted" missed. Fixed in round 623: `304 ms`.
The deterministic arm is `test/resilience/a_cancel_cuts_the_retry_backoff_test.dart`;
this probe stays as the record of how jitter hid it.

## Measures

Wall-clock from call start to completion, and the status returned. The status matters
as much as the time: `1` says cancellation won, `14` says the retries were exhausted.

## Control

**The never-cancelled arm is the one that makes the table readable, and it was added
second.** With only the two cancel arms both read ~1.7 s and the result was
uninterpretable — there was nothing for them to be shorter THAN. Against 5237 ms it is
clear the cancellation shortens the call.

The immediate-cancel arm is the other control, and it is what exposes the residual
lag: a cancel at t=0 still takes 1504 ms.

## What it establishes, and what it does not

Establishes: the call does NOT sit out `maxDelay` after a cancel. Item 13's stated
claim is refuted.

**Does NOT explain two numbers, and the round says so rather than rounding them off:**

- a ~1.5-1.8 s lag between the cancel and completion, present even when cancelling at
  t=0 — not prompt, and not the 4 s backoff either;
- an uncancelled baseline of 5237 ms where `maxAttempts: 5` at 4 s implies roughly
  16 s, so something ends the retry sequence early.

Either could be a defect, a deadline interacting, or a property of the interceptor
nobody has written down. Nothing here distinguishes them.
