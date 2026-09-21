---
round: 424
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — three defects from B-56's nine-site sweep; the evidence is two
  ablations, one of which is a WALL-CLOCK number the witness asserts directly
commit: yes
---

# Round 424 — the rule written thirty lines above

## Target

**B-56's three DEFECTS**, not its refactor. The lead's sweep found nine sites of
one mechanic — drive a user-supplied stream into a call — and named three that
are wrong today:

```
site                          missing
7 CallScope.track             pause/resume forwarding
8 CallScope.listen            pause/resume forwarding, AND it awaits the cancel
9 circuit breaker abandon     the cancel Future is dropped BARE
```

The nine-site helper extraction is deliberately NOT in this round; see
`## Not fixed`.

## Hypothesis

Three small corrections.

They were. What is worth recording is not the difficulty but **where the rules
already were**.

## Before

`RpcCallScope.listen` ends with `onDispose(sub.cancel)`. Disposers are AWAITED,
with `disposerTimeout` as the only bound:

```dart
await Future<void>.value(_disposers[i]()).timeout(disposerTimeout);
// disposerTimeout = 5 seconds
```

So closing a scope holding a parked generator cost **up to five seconds per
subscription** — measured by the canary below at the full budget.

Thirty lines above it, `track` does the same job correctly and states both rules
and their price:

> *"Not awaited: cancelling a suspended generator can block indefinitely and the
> scope has to finish closing. Both this and the onCancel above dropped the
> returned future outright, so a rejected cancel became TWO unhandled async
> errors — measured, and enough to kill the isolate."*

`listen` was written with neither. And the circuit breaker's abandon timer
(`sub.cancel();`, bare, on a detached callback) is the second half of that same
sentence, in a different file.

## Mechanism

The criterion that makes these one class is OWNERSHIP: a stream the library
built cannot park on cancel; one handed in by a user, or built from a user's
`async*`, can. That is the whole reason L-16 exists — and it is why the
transports' 17 awaited-cancel sites are NOT in this class, as the lead says.

## After

`listen` cancels unawaited and catches; both `track` and `listen` forward
`onPause`/`onResume`; the abandon timer's cancel is `unawaited(...)` with a
`catchError`.

## Canary

```
fix switched off                    witness failed with
onDispose(sub.cancel)               close() took 5006ms against a 2000ms bound
  (the awaited cancel)              -- the full disposerTimeout, which is the
                                    defect stated as a number
track's onPause/onResume            "without onPause forwarding, the controller
                                    buffers without bound while the producer
                                    runs flat out"
```

Both GUARDs stayed green under their own ablation: an ordinary subscription is
still cancelled (so the fix is not "leak them"), and `track`'s cancel discipline
— which was already right — still is.

The first canary is the honest one to read. Five seconds is not a threshold I
chose; it is `disposerTimeout`, and the witness bound is 2000 ms precisely so
the failure cannot be confused with slowness.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant
melos run test:web       SUCCESS — dart2js
```

## Not fixed

**B-56's actual subject — one helper owning the discipline across nine sites —
is NOT done, and this round does not claim it.** What is done is the three
places that are wrong. The extraction remains, and the lead's own constraints
say why it is its own work: convert one call site at a time with its existing
witness green after each, because five at once leaves a regression with five
candidate causes. It also has a designated source — site 6,
`_bridgeCallerResponses`, the only one carrying the "fire the cancellation token
ONLY when the stream did not already finish" clause, whose loss poisons a reused
`RpcContext`.

Scoped honestly rather than discovered at the end: this round took the defects
because they have damage, and left the refactor because it needs a round that
can spend itself on one file at a time.

**The circuit-breaker fix has no witness.** Its failure mode is an unhandled
async error from a REJECTED cancel on a detached timer, which needs a source
that rejects rather than parks; the two existing abandon-probe suites cover the
surrounding behaviour and stay green. Stated rather than implied.

**Sites 1-6 were confirmed correct by the sweep and are untouched.** That is a
READ, not a measurement — the lead says so — and this round did not re-take it.

## Links

- B-56 — three defects closed; the extraction stays open
- L-16 — cancel UNAWAITED; both defects here are it, one of them thirty lines
  under a comment stating it
- RPC-25 — and the reason a rule written down next door still did not travel:
  it was in a comment, not in a function
