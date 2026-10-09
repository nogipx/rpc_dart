---
file: packages/core/rpc_dart/.dart_tool/probe/b123_drain_latency.dart
round: 514
commit: d64caa1a
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/core/drain.dart]
status: valid
---

# P-152 — how long does a drain take when its work is already done?

## Why it exists

A poll interval is invisible in any measurement that lets the work take longer than
the interval. The lead's own witness names the case that exposes it: the last call
finishing a millisecond into the drain. Everything after that millisecond is the
polling, and nothing else.

## The harness

One in-flight call whose handler parks on a completer, so the moment it finishes is
controlled exactly. The drain starts, the completer is released after `finishAfter`,
and the drain's own duration is timed with a `Stopwatch`.

A 60 ms settle before the drain starts, so the call has actually reached the handler
— a drain with nothing yet in flight returns immediately and would measure nothing.

## The numbers (round 514)

```
handler finishes into the drain      before      after
                    1 ms             52 ms       5 ms
                    5 ms             51 ms       7 ms
                  120 ms            156 ms     122 ms   <- control
```

## Measures

Wall-clock duration of `drain()` itself, by `Stopwatch`. The quantity is latency, so
it is the only thing worth measuring here.

## Control

**The 120 ms arm, where the handler genuinely runs that long.** The drain must take
about that long, and it does — which is what stops the other two rows being read as
"the drain got faster" when the honest reading is "the drain stopped waiting for work
that was finished".

It carries a second fact the round would otherwise have missed: `156 ms` before
against `122 ms` after. Even when the work dominates, polling added ~36 ms of
rounding. So the fix is not only about the pathological case.

## What it establishes, and what it does not

Establishes: `_runDrain` polled at 50 ms, so ~51 ms of a 52 ms drain was waiting for
a tick after the work was done. Signalling from `_cleanupStream` brings it to 5 ms,
and the control confirms a genuinely slow handler is still waited for.

Does NOT establish anything about the wall-clock claim. `DateTime.now()` was used for
both deadlines and is now a Timer in one and a `Stopwatch` in the other, but nothing
here steps a clock — that half is fixed on the same argument
`RpcCircuitBreakerInterceptor` already documents for its own `Stopwatch`, not on a
measurement.

Does NOT cover `drainUntilIdle`, which still polls at 25 ms. It is generic over a
`pending()` callback, so it has nothing to be signalled by; only its budget changed.

Does NOT measure `activeResponderCount`'s O(n) `where`, the lead's third claim.

## Reading

rpc_dart — a poll interval is invisible in any measurement that lets the work
take longer than the interval, so the handler parks on a completer and the
moment it finishes is controlled exactly. **Its control did more than validate
the rig**: the 120 ms arm read `156 ms` before against `122 ms` after, which
is how the round learned polling added ~36 ms of rounding even when the work
dominated — a fact the lead does not mention. A 60 ms settle before the drain
starts, because a drain with nothing yet in flight returns immediately and
measures nothing.
