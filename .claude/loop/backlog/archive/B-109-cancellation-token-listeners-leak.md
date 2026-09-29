---
status: closed (round 500)
round: 500
commit: 5d226412
paths: [packages/core/rpc_dart/lib/src/contracts/call_scope.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart]
probe: P-138
reason: "closed — REFUTED at the primitive: cancelling an asStream subscription DOES detach, 0 callbacks against a control's 100; negative in checked/C-58"
---

# B-109 — every call on a reused cancellation token leaves a listener on the token forever

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The token is observed through `token.cancelled.asStream().listen(...)`; cancelling that subscription does not detach the callback `asStream` registered on the Future, so each call on a long-lived token (the reused-context case the caller pipeline explicitly supports) adds a permanent closure + controller until the token is cancelled.

## The shape

Sites: `call_scope.dart:283`, `base_processor.dart:841` and `:1345`,
`unary/caller.dart:167`, `unary/responder.dart:160`. A streaming call on a
CallProcessor registers two (its scope and its monitor). Futures have no
unsubscribe; `Future.asStream` keeps its `then` callbacks.

## Why it matters

An app that passes one token (per screen, per session) to many calls grows memory
linearly with the number of calls made, never with the number in flight.

## Witness a round would build

One token, 100k sequential unary calls on an in-memory pair; heap after GC.
Control: a fresh token per call.

## Fix sketch

Give `RpcCancellationToken` a real listener API (`addListener`/`removeListener`)
and use it at every site.

## Closed (round 500) — REFUTED at the primitive

The mechanism is a claim about Dart, not about this library, and it is twelve
lines to check:

```
100 asStream subscriptions, CANCELLED    -> callbacks fired =   0
100 asStream subscriptions, left open    -> callbacks fired = 100   <- control
```

Cancelling DOES detach. Nothing accumulates however long the token lives. The
control is what makes the zero admissible — same loop, same future, one line
different.

**The census the primitive does not cover.** A site observing the token with a
bare `cancelled.then(` really would retain its callback until the token completed;
that is the true version of this concern. Every observer in `lib/`:

```
call_scope.dart:283            asStream().listen, cancelled at :211
base_processor.dart:841        _scope.listen, owned and cancelled by the scope
base_processor.dart:1345       _scope.listen, owned and cancelled by the scope
unary/caller.dart:167          asStream().listen, cancelled in the finally
unary/responder.dart:160       asStream().listen, cancelled at :756
ping.dart:244                  asStream().listen, cancelled in the finally
```

Six of six use the subscription form, six of six cancel it, and
`cancelled.then(` / `cancelled.whenComplete` appear nowhere.

Negative: `checked/C-58`.

## What the sketch would still buy

`addListener`/`removeListener` on `RpcCancellationToken` is now a change with **no
defect behind it**. It would still be the clearer contract — a `Completer` used as
a broadcast notification is an idiom that invites exactly this doubt, which is
presumably why the audit raised it — but that is a design preference and the
owner's, not a leak.

Not covered: RSS growth on a reused context in a real application. The bench's
level-2 arm measured 20 000 calls and produced 50 MiB of noise with opposite signs
between arms. If a consumer reports growth there, this negative does not answer it.

## Owner decision

—
