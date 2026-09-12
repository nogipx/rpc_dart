---
round: 351
verdict: FIXED
packages: [rpc_dart]
lens: RPC-05
bench: P-43 — new
commit: yes
---

# Round 351 — the probe ending nobody wired

## Target

The owner's 6.0.0 review list, P0 item 1, taken in the order the list gives.
`next` named no target and the list overrides its state anyway: fifteen named
defects, twenty rounds to the cap, one per round.

The shape is RPC-05's, and its last section states this defect in the abstract
already — *"charging is only half a lifecycle: enumerate the endings, not the
happy path"*. The lens's `applies:` says `RpcSecurityPolicy` field, and this gate
is not one; round 245 had already widened it past policy fields once, so the
`applies:` is corrected here rather than a new lens minted for a third instance
of the same shape.

**Scope, counted before the fix.** The class is *a half-open probe gate charged
by `_checkState` and released only on endings that some path skips*. Its
instances:

```
ending                              releases the gate
unary / clientStream, any outcome   yes -- try/catch around the await
stream source onDone                yes -- _onSuccess
stream source onError               yes -- _onFailure
an outcome failureOn rejects        yes -- fixed already, da530ac0
never listened, source never ends   yes -- the abandon timer
listened, then cancelled            NO
```

One code site, `_wrapStream`'s `onCancel`, reachable from two public entry
points (`interceptServerStream`, `interceptBidirectionalStream`). Swept wider:
the only other interceptor in the workspace that wraps a stream around per-call
state is `rpc_dart_opentelemetry`'s `_wrapWithSpan`, and it already ends its span
in `onCancel` — the sibling that gets it right (U-14). The rate limiter holds no
permit across a call; the framework's spy and fault injector wrap no streams.

## Hypothesis

A consumer that listens to a half-open stream probe and then cancels —
`stream.first`, `take(n)`, a disposed widget — hits no release path at all.
`onListen` has already cancelled the abandon timer, and a cancelled subscription
never delivers `onDone`. If so the gate stays pinned, the breaker stays
half-open, and every later call on that breaker is refused forever, with nothing
but a manual `reset()` to clear it.

It fails to hold if the source's termination reaches the gate anyway, or if the
abandon timer covers the case.

## Before

```
arm                   state after probe   admitted/attempted
keep-serverStream     closed              5/5     control
cancel-serverStream   halfOpen            0/5
keep-bidi             closed              5/5     control
cancel-bidi           halfOpen            0/5
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/cancelled_stream_probe_wedges.dart`.

The control is the same consumer without the cancel, with the source closed at
the same point in both arms. `probeAbandonTimeout` is 30 s so the safety net
cannot be what releases anything here.

## Mechanism

`_checkState()` admits one half-open probe by setting `_probeInFlight = true`.
`_wrapStream` releases it from three places: the source's `onError`, the source's
`onDone`, and the abandon timer. `onListen` cancels that timer — the stream is
being consumed, so the safety net is not needed — and `sub.cancel()` on the
source means `onDone` never arrives. `onCancel` did nothing but forward the
cancel, with a comment asserting the gate "is released by source termination or
the abandon timer, not here". By then neither can fire.

## After

```
arm                   state after probe   admitted/attempted
keep-serverStream     closed              5/5     control, unchanged
cancel-serverStream   halfOpen            5/5     <- was 0/5
keep-bidi             closed              5/5     control, unchanged
cancel-bidi           halfOpen            5/5     <- was 0/5
```

`halfOpen` is read before those five calls: the gate is free and the next call
takes its turn as the probe, which is what an inconclusive outcome should leave
behind. The first of the five closes the breaker.

## Canary

`onCancel`'s `resolveInconclusive()` short-circuited in place. Both witnesses in
`circuit_breaker_cancelled_stream_probe_test.dart` failed with

```
CircuitBreakerOpenException: circuit is open
package:rpc_dart/src/resilience/circuit_breaker_interceptor.dart 305:11  _checkState
```

— a real refusal from the gate, not a timeout, and it names `_checkState`, the
line under test. The two guards in the same file stayed green under the ablation
(`+2 -2`), which is what makes them guards: the drained probe still closes the
breaker and the failing probe still reopens it, so the release did not swallow
the outcomes that decide the state.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS over 14 packages;
`melos run format:check` SUCCESS; `melos run license:check` — 1336/1336 files,
0 bad licences. Plus `fvm dart test test/resilience/` in the changed package,
129 passed.

## Not fixed

**The abandon timer answers an unknown outcome with a fabricated success.** A
probe whose stream is never listened and whose source never terminates is
released after `probeAbandonTimeout` by `resolve(success: true)` — which does not
merely free the gate, it CLOSES the breaker and reopens full traffic to a service
that was never observed to recover. Same charge point, different wrong answer:
that ending releases, so it is not an instance of the wedge class this round
scoped, and `audit_circuit_breaker_abandoned_probe_test.dart:155` deliberately
pins `closed` there. With `_releaseProbe()` now in place the change is one line,
but it is a behaviour change to a prior deliberate decision, not a wedge. Filed
as B-36.

## Links

Lens `../lenses/RPC-05-concurrency-limit-charge-point.md` (`applies:` widened
past policy fields; sixth application). Bench `../probes/P-43-cancelled-stream-probe.md`, new.
Lead `../backlog/B-36-the-abandon-timer-fabricates-a-success.md`, new.
Catalog shape U-07; sibling comparison is U-14.
