---
status: closed (round 420)
round: 420
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

**Taken: leave it half-open.** `_releaseProbe()` instead of
`resolve(success: true)`, so the next call takes its turn as the probe.

An unobserved probe is not evidence of recovery, and treating it as one is the
only ending in this class that invents a result rather than declining to state
one.

**The pinned test moves, and the replacement is the stronger claim.**
`audit_circuit_breaker_abandoned_probe_test.dart:155` asserts `closed` under the
reason *"abandon safety timer must release a wedged half-open probe"* — the
reason names the RELEASE and the assertion observes it through the CLOSE. Those
came apart the moment the close became wrong, and the reason is the half worth
keeping.

So the new assertion is `halfOpen` **plus a following call that is admitted**.
That checks the gate directly, where `closed` only checked a state a fabricated
success also produces — which is how the wrong outcome passed for as long as it
did.

## Closed — round 420

The abandon timer calls `resolveInconclusive()`, which already existed three
lines above doing exactly this for the cancel path: release the gate, record no
outcome. The breaker stays HALF-OPEN and the next call takes its turn as the
probe, which is a real observation rather than an invented one.

**The pinned test moved exactly as this record predicted**, and the replacement
is the stronger claim: `halfOpen` PLUS a following call that is admitted. The
old assertion's reason named the RELEASE while the assertion observed it through
the CLOSE — and `closed` is also what a fabricated success produces, so it could
not tell the two apart.
