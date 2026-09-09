---
round: 242
verdict: FIXED
packages: [rpc_dart]
lens: RPC-13
bench: P-20 — new
commit: yes
---

# Round 242 — the callback that ends the isolate

## Target

RPC-13's sweep is `swept here (round 222, b8d934a2)` and `next` reported ten
files moved under its paths since — the largest drift of the six stale sweeps,
and rounds 234-241 put new code on exactly those paths. Its damage class is a
process crash, which clears the bar without argument.

Passed over: RPC-06 still needs a booted device; B-24 and B-25 were filed by the
two previous rounds and both wait on the owner or on an hour of cycles; B-23
still needs the owner's call on six of its files.

## Hypothesis

The 222 sweep found every `unawaited(...)` on a user-code path guarded. If new
code since then added an unguarded one — or an old site became reachable — a
throw on that path ends the isolate.

## Before

The detector points at futures spawned without `await` and without a handler on
paths that run user code. `forceReconnect()` has one, and its comment says so
itself: `_proxy.detach().then((_) { _emit(...); _connectWithBackoff(); })`, no
`onError`. Round 235 made `detach()` unable to reject, which left the `.then()`
safe by a property of a DIFFERENT method — and `_emit` then calls
`_onStateChanged`, which is user code, with no guard at all.

```
arm                     unhandled  transports built
control                     0            2
onStateChanged throws       1            0
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/state_callback_kills_the_zone.dart`
(P-20).

## Mechanism

`_emit` calls the user's `onStateChanged` synchronously. Every caller of `_emit`
that sits inside an unhandled future turns a throw there into an unhandled async
error, and in an application that is the root zone, where it ends the isolate.

The second number is the one reading would have missed: the throw also aborted
the connect loop before the factory was called even once, so the client was not
merely noisy but silently not connected.

## After

```
arm                     unhandled  transports built
control                     0            2
onStateChanged throws       0            2
```

Same probe. The callback's exception is logged at warning and dropped, which is
what `detach()` already does with a user transport's throwing `onCancel`.

## Canary

`state_callback_that_throws_test.dart`, with the try/catch removed in place:

    Expected: <0>              Actual: <1>     (the zone error)
    Expected: >= <2>           Actual: <0>     (transports built)

Two witnesses, because the defect has two damages and the second does not follow
from the first. The third test — the same drive with a callback that returns
normally — passed on BOTH sides, so it is the guard, not evidence.

## Gate

`melos run analyze` SUCCESS (21 members + wasm) · `melos run test:unit
--no-select` SUCCESS · `melos run format:check` SUCCESS · `melos run
license:check` REUSE compliant. In the package: analyze clean, `fvm dart test
-j 8` 1417 passed / 1 skipped.

## Not fixed

**The unguarded `.then()` in `forceReconnect()` is still unguarded.** This round
removed the only thrower reachable through it, which is the minimal fix at the
point that renders the wrong verdict; it did not make the call site safe against
a future thrower. That is the same "safe by coincidence" shape as B-24, and it
is worth an `onError` the next time this file is opened.

`dart test -p node` still cannot run in this environment (`read ENETDOWN` at
load, on untouched files too), so the dart2js side of this change is unmeasured.

## Links

Lens RPC-13 (re-swept, confirmed again — refines catalog U-17) · bench P-20
(new) · the sibling guard this fix copies is in `detach()`, round 235 ·
B-20 already records that this lens's guards have no witnesses.
