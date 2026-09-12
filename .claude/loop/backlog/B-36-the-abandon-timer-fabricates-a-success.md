---
status: open
round: 351
commit: 2fca444c
paths: [packages/core/rpc_dart/lib/src/resilience/circuit_breaker_interceptor.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/cancelled_stream_probe_wedges.dart
reason: "a behaviour change to a prior deliberate decision that an existing test pins, not a wedge — the gate IS released, so it is outside the class round 351 scoped, and closing a breaker on no evidence is a degradation rather than one of the very-critical shapes the bar names"
---

# B-36 — the probe abandon timer answers an unknown outcome with a success

## What the code does

`_wrapStream`'s safety timer covers a half-open stream probe that is never
listened and whose source never terminates:

```dart
abandonTimer = Timer(probeAbandonTimeout, () {
  if (resolved || listened) return;
  resolve(success: true);
  sub.cancel();
});
```

`resolve(success: true)` calls `_onSuccess()`, which in `halfOpen` sets
`_failureCount = 0` and moves the breaker to `closed`. Nothing was observed: the
probe produced no item, no error and no done event. The breaker reopens full
traffic to a service it has no evidence recovered.

## Why it is a lead and not this round's fix

Round 351 scoped the class *a probe gate that is never released* and fixed its
one instance, the consumer cancel. This ending DOES release the gate — it gives
a wrong answer rather than no answer, which is a different mechanism and a
different severity. Against the config's bar it is a degradation (a thundering
herd at a still-dead service), not a hang, a leak or a crash.

It is also pinned: `test/audit/audit_circuit_breaker_abandoned_probe_test.dart`,
`safety timer releases probe when abandoned source never completes`, asserts
`CircuitBreakerState.closed` at line 155 with the reason *"abandon safety timer
must release a wedged half-open probe"*. The reason names the release; the
assertion observes it through the close. Changing the outcome means deciding
which of the two the test was protecting.

## What a fix would be

One line now that round 351 added `_releaseProbe()`: call the inconclusive
resolution instead of `resolve(success: true)`, leaving the breaker half-open so
the next call takes its turn as the probe. The audit test's assertion would move
from `closed` to `halfOpen` plus a following call that is admitted — the stronger
statement, since it checks the gate rather than a state that a fabricated
success also produces.

## Owner decision

Whether an unobserved probe should close the breaker (today) or leave it
half-open for the next caller (proposed). Round 351 recommends the latter: it is
what every other inconclusive ending in this class already does.
