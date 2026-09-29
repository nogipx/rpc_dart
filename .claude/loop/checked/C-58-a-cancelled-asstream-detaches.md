---
round: 500
commit: 5d226412
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/contracts/call_scope.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/endpoint/ping.dart]
scope: [rpc_dart]
---

# C-58 — a cancelled asStream subscription detaches, so a reused token does not accumulate

Bench: `../probes/P-138-does-a-cancelled-asstream-detach.md`.

> **Scope**: Dart 3.10.1. This is a statement about `Future.asStream()` in that
> SDK plus a census of the six sites in this library at `5d226412`.

## The claim that was checked

B-109: *"cancelling that subscription does not detach the callback `asStream`
registered on the Future, so each call on a long-lived token adds a permanent
closure + controller until the token is cancelled."*

## The numbers

```
100 asStream subscriptions, CANCELLED    -> callbacks fired =   0
100 asStream subscriptions, left open    -> callbacks fired = 100   <- control
```

**REFUTED at the primitive.** Cancelling detaches. The lead's mechanism does not
exist, so nothing accumulates however long the token lives.

## Control

The uncancelled arm is what makes the zero admissible: same loop, same future,
one line different, 100 callbacks against 0. A bench that only ran the cancelled
arm would report the same zero if its counter were never wired up.

## And the census, because the primitive alone is not the whole answer

A site that observed the token with a bare `.then(` and no subscription WOULD
retain its callback until the token completed — that is the real version of this
concern. Every observer in the library was read:

```
call_scope.dart:283            asStream().listen, cancelled at :211
base_processor.dart:841        _scope.listen, owned and cancelled by the scope
base_processor.dart:1345       _scope.listen, owned and cancelled by the scope
unary/caller.dart:167          asStream().listen, cancelled in the finally
unary/responder.dart:160       asStream().listen, cancelled at :756
ping.dart:244                  asStream().listen, cancelled in the finally
                               (added by round 499, same shape)
```

Six of six use the subscription form and six of six cancel it. `grep` for
`cancelled.then(` and `cancelled.whenComplete` across `lib/` returns nothing.

## What this does NOT settle

The fix sketch's API — giving `RpcCancellationToken` an
`addListener`/`removeListener` pair — is now a change with no defect behind it.
It would still be the clearer contract (a Completer used as a broadcast
notification is an idiom that invites exactly this doubt), but that is a design
preference and the owner's, not a leak.

Says nothing about the RSS of a long-lived token in an application: level 2 of the
bench measured 20 000 calls and produced 50 MiB of noise with opposite signs
between arms. If a consumer reports growth on a reused context, this negative does
not cover it — it covers the stated mechanism.
