---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/contracts/call_scope.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
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

## Owner decision

—
