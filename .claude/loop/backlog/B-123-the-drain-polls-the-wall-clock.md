---
status: closed (round 514)
round: 514
commit: d64caa1a
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/core/drain.dart]
probe: P-152
reason: "closed on the responder drain — CONFIRMED at 52 ms for work that finished at 1 ms, now 5 ms, and the control showed polling added ~36 ms even when the work dominated. drainUntilIdle still polls (nothing to be signalled by) and the shared-implementation half remains"
---

# B-123 — both drains poll on a timer and measure their budget on the wall clock

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_runDrain` sleeps 50 ms and `drainUntilIdle` 25 ms in a loop against `DateTime.now()`, and `activeResponderCount` is an O(n) `where` per tick; a clock step shortens or extends the budget.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart:607-641`, `core/drain.dart:73-98`,
`responder_pipeline.dart:582-584`.

## Why it matters

Shutdown latency of up to one poll interval, a wrong budget under NTP steps, and
two copies of one mechanism.

## Witness a round would build

Drain with zero in-flight calls finishing at t=1 ms: measured completion time.

## Fix sketch

A completer signalled when the last stream is cleaned up, a `Stopwatch` for the
budget, one implementation.

## Outcome (round 514)

**CONFIRMED and fixed on the responder drain.**

```
handler finishes into the drain      before      after
                    1 ms             52 ms       5 ms
                    5 ms             51 ms       7 ms
                  120 ms            156 ms     122 ms   <- control
```

~51 ms of a 52 ms drain was waiting for a tick after the work was done. **The control
row gave the round something this lead does not mention**: a handler that genuinely
ran 120 ms still made the drain take 156 ms, so polling added ~36 ms of rounding even
when the work dominated.

Fixed as the sketch says: `_cleanupStream` completes a waiter when the active-stream
count reaches zero, and `_runDrain` awaits it with `.timeout(timeout)` — a Timer
rather than a `DateTime.now()` comparison, so the budget half lands in the same edit.

**The signal sits before `_cleanupStream`'s early return, deliberately.** That method
returns early when the id had no state, but what a drain waits for is the COUNT
reaching zero, which is true either way.

## Still open

**`drainUntilIdle` still polls at 25 ms**, so "two copies of one mechanism" is still
two. Its budget is now a `Stopwatch`, but it is generic over a `pending()` callback
and has nothing to be signalled BY — unifying them means giving it something to wait
on, which changes its signature and every caller. Worth doing; it is its own change.

**The wall-clock claim is fixed without being measured.** Nothing stepped a clock.
Both deadlines are monotonic now on the argument `RpcCircuitBreakerInterceptor`
already documents for its own `Stopwatch` — reasoning, not evidence.

**`activeResponderCount`'s O(n) `where` per tick is untouched.** With the responder
drain no longer ticking, the site that called it per tick is gone; whatever else polls
it was not measured.

## Owner decision

—
