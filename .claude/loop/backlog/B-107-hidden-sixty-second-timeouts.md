---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-107 — unary and client-stream calls hide a 60 s timeout, never tell the server, and the other shapes have none

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

With no deadline, `UnaryCaller` waits `timeout ?? remainingTime ?? 60s` and `ClientStreamCaller` `_noDeadlineFallback = 60s`; no `grpc-timeout` is sent and on expiry only the id is released — no reset, no cancel notice — so the server handler keeps running; server-stream, bidi and zero-copy unary have no bound at all.

## The shape

`packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart:91-92`:

```dart
final effectiveTimeout = timeout ?? remainingTime ?? const Duration(seconds: 60);
```

On timeout the `finally` (`:592-623`) cancels the subscription and releases the
id; `_notifyPeerOfCancellation` runs only from the token listener (`:166-193`).
`client/caller.dart` `_noDeadlineFallback = Duration(seconds: 60)` and
`unawaited(close())` on timeout. Zero-copy unary goes through
`_executeUnaryCall` (`caller_pipeline.dart:786-821`) with no timeout.

## Why it matters

A legitimate unary call longer than 60 s fails client-side with a
`TimeoutException` nobody configured, while the server finishes the work and
sends a response to nobody. Four call shapes, three different behaviours for the
same missing deadline.

## Witness a round would build

Unary handler taking 61 s with no deadline: client outcome, and whether the
server handler observes cancellation. Repeat for client-stream and the zero-copy
unary path.

## Fix sketch

Either no implicit timeout anywhere (the gRPC default), or one documented default
applied to every shape, sent as `grpc-timeout`, and followed by a cancel notice on
expiry.

## Owner decision

—
