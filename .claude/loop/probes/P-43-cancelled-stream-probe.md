---
file: packages/core/rpc_dart/.dart_tool/probe/cancelled_stream_probe_wedges.dart
round: 351
commit: 2fca444c
paths: [packages/core/rpc_dart/lib/src/resilience/**]
status: valid
---

# P-43 — what a circuit breaker admits after a half-open STREAM probe

Trips the breaker at `failureThreshold: 1`, waits out `resetTimeout`, takes the
half-open probe through `interceptServerStream` and through
`interceptBidirectionalStream`, then counts what the next five unary calls get.
Point it at another probe ending by changing what the consumer does between
`listen` and `source.close()`.

`probeAbandonTimeout` is set to 30 s on purpose: the abandon safety net must
never be the thing that releases the gate, or the refusal names a neighbouring
limit instead of the path under test.

## Measures

Two numbers, both on the library's side: `cb.state` (the breaker's own getter)
after the probe ends, and how many of five following unary calls `_checkState`
admitted rather than throwing `CircuitBreakerOpenException`.

## Control

**One variable: whether the consumer cancelled its subscription.** Both arms
listen, both see one item, and the source is closed at the same point in both,
so "the source terminated" is held fixed and is not what differs.

An earlier version varied two things — cancel, AND whether the source ever
closed — and had to be rebuilt. A drain arm that closes the source while the
cancel arm leaves it live cannot tell "cancel skips the release" from "a live
source has not released yet".

```
arm                   state after probe   admitted/attempted
keep-serverStream     closed              5/5     control
cancel-serverStream   halfOpen            0/5     <- before
cancel-serverStream   halfOpen            5/5     <- after
keep-bidi             closed              5/5     control
cancel-bidi           halfOpen            0/5     <- before
cancel-bidi           halfOpen            5/5     <- after
```

The control is identical before and after, which is what makes the case arms
mean something: the fix moved only the ending it was aimed at.
