---
round: 647
verdict: FIXED
packages: [rpc_dart]
lens: RPC-13
bench: none — the witness test is the measurement; the coverage-review probe is cov_core_long_timer.dart
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 647 — a late source beats the timeout

## Target

A coverage-review finding (round 640): `RpcLongTimer.timeout` with an
asynchronous `onTimeout`.

## Hypothesis

It keeps `Future.timeout`'s contract: once the timer fires, the replacement is
the result.

## Before

```
timer 10 ms, source completes at 20 ms, async onTimeout settles at 40 ms
sync onTimeout     result=timeout
async onTimeout    result=source   then ZONE ERROR: Bad state: Future already completed
async, throws      result=source   then ZONE ERROR: Bad state: Future already completed
```

## Control

The synchronous `onTimeout` row.

## Mechanism

RPC-13. While the replacement was pending, the source's handler completed the
completer; the replacement then completed it again from inside a `then` whose
derived future nobody listens to, so the error reached the zone -- the hazard
the function's own comment says it prevents. Latent: every in-library caller
passes a synchronous `onTimeout`.

## After

The timer marks the race lost for the source; its result is still consumed and
ignored. Both async arms return the replacement, nothing in the zone.

## Canary

The mark removed: both witness arms read `'source'`.

## Gate

Recorded in round 650.

## Not fixed

Nothing known.

## Links

Lens `../lenses/RPC-13-unhandled-async-error.md` — `applied: [..., 647]`.
Test `packages/core/rpc_dart/test/core/long_timer_test.dart` ("a late source
does not beat an async onTimeout").
