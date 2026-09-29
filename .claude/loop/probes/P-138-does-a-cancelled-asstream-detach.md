---
file: packages/core/rpc_dart/.dart_tool/probe/b109_token_listeners.dart
round: 500
commit: 5d226412
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/contracts/call_scope.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart]
status: valid
---

# P-138 — does a cancelled asStream subscription detach?

## Why it exists

B-109 rests on a claim about a Dart primitive, not about this library:
*"cancelling that subscription does not detach the callback `asStream` registered
on the Future"*. If that is false the lead has no mechanism, and it is cheaper to
ask the primitive than to hunt for a leak.

## The harness

Level 1, twelve lines and nothing of the library in it: 100
`completer.future.asStream().listen(...)` subscriptions, then complete the
future and count the callbacks that ran.

Level 2, the library: 20 000 sequential unary calls over a channel pair, one
shared token against a fresh token per call.

## The numbers (round 500)

```
100 asStream subscriptions, CANCELLED    -> callbacks fired =   0
100 asStream subscriptions, left open    -> callbacks fired = 100   <- control

20000 calls, one shared token   RSS +24096 KiB
20000 calls, a token per call   RSS -25504 KiB
```

## Measures

Callbacks that actually ran, counted by the callback itself. That is the whole
question: a retained `then` callback runs when the future completes, a detached
one does not.

## Control

**The uncancelled arm, and it is what makes the zero mean anything.** 100 fired
with the subscriptions left open, 0 with them cancelled — same loop, same future,
one line different. Without it, `fired = 0` is indistinguishable from a counter
that was never wired up.

Level 2's RSS is NOT a control and should not be read as one: the two arms differ
by 50 MiB with opposite signs, and an earlier run of the same code gave `-3424`
and `-160`. It is GC noise, the trap `methods/measurement.md` item 7 names and
P-128 already paid for. Level 1 is the evidence.

## What it establishes, and what it does not

Establishes: cancelling an `asStream()` subscription DOES detach the callback, so
the mechanism B-109 describes does not exist.

Does NOT establish that no token-related leak is possible — only that this one is
not. A site that observed the token with a bare `.then(` and no subscription
WOULD retain its callback until the token completed; the round checked all five
named sites and none does. And a site that stores a subscription but never
cancels it would leak for an unrelated reason; all five cancel.
