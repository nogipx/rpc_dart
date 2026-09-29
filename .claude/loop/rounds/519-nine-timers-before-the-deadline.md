---
round: 519
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-17
bench: P-156 — new
commit: yes
---

# Round 519 — nine timers before the deadline

## Target

A server call arming several timers for one deadline — thirty-fourth in the audit's
rank.

Lens RPC-17, in round 511's reading: ask what the work is FOR. One deadline is one
fact about a call; the machinery for it is per-owner rather than per-fact.

## Hypothesis

`state.armDeadline`, the context's `RpcCallScope` and the StreamProcessor's own
`RpcCallScope` each arm a timer for the same deadline, and `RpcCallScope.close`
wraps every disposer in `.timeout()` including synchronous ones.

## Before

```
unary, WITH a deadline               4.0 timers/call
CONTROL unary, no deadline           2.0 timers/call
server stream, WITH a deadline      14.1 timers/call
CONTROL server stream, none          9.1 timers/call
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b127_timers_per_call.dart`

**CONFIRMED in shape, refuted in its number.** A deadline costs **2 timers on unary
and 5 on a server stream** — not three, and not a constant. The lead's mechanism is
right; its arithmetic is per-shape.

**And the control is where the surprise is: a server-stream call arms nine timers
before any deadline exists.** That is larger than the thing the lead is about, and it
is not what the lead is about at all.

Both secondary claims verified by reading: `static Duration disposerTimeout` is a
mutable process-wide field, and `call_scope.dart:229` wraps EVERY disposer —
`await Future<void>.value(_disposers[i]()).timeout(disposerTimeout)` — so a
synchronous disposer allocates a Timer to bound work that cannot block.

## Mechanism

Not fully localised, and the record says so. The Zone counts timers; it does not say
which site created which. Attributing them needs a stack capture per creation, which
this round did not build.

## After

Nothing. `lib/` is unchanged.

## Canary

n/a — nothing was fixed.

**What stands in for it is the rig's own correction.** The first version built the
endpoints OUTSIDE the counted zone and reported `1.0 timers/call` for unary with the
deadline apparently free. A stream subscription creates its timers in the zone it was
registered in, so every RESPONDER timer landed in the root zone — uncounted, and the
responder is the half this lead is about. Everything now runs inside one zone, with
the counters zeroed after an in-zone warm-up.

**A measurement that makes a claim vanish deserves the same suspicion as one that
confirms it too easily.** `1.0` for both arms said "the deadline is free", which was
the rig, not the code.

## Gate

Not run: nothing in `lib/` or `test/` changed.

## Not fixed

**The fix sketch is "one deadline owner per call", and it cannot be designed from
this measurement.** Knowing that a deadline costs 2 or 5 timers does not say which of
the three arming sites is redundant — and the three are in different layers
(`responder_streams`, `call_scope`, `base_processor`), each with its own lifetime and
its own teardown. Consolidating them is a change to how a call's cancellation is
owned, on a hot and well-tested path.

Round 518 is the immediate precedent for not attempting that on partial information:
a plausible fix to one layer of a three-layer mechanism turned a clear error into a
hang.

**"Time out only asynchronous disposers" is the separable half and is much cheaper.**
`Future.value(x).timeout(d)` allocates a Timer for a value that is already available;
checking whether the disposer returned a Future before wrapping removes that without
touching deadline ownership. It was not done here because it is a different change
from the one the round set out to make, and it deserves its own before/after.

**`disposerTimeout` being a mutable static is untouched.** Any test or library in the
process can change it for everyone, which is the lead's own point and is a small,
separable API decision.

**The nine-timer floor on a server stream is unexplained** and is the largest number
in the table. Nothing here investigated it.

## Links

Lens RPC-17. Bench P-156 (new). Lead B-127 (awaiting owner). Round 518 is the
precedent for declining a partial fix across layers.
