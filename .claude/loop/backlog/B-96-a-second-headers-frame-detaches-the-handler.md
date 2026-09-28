---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-96 — a second metadata frame with a methodPath replaces a running call's context

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

For an existing stream `storeMetadata` clears the cache and `_cacheContext` builds a NEW context — new token, new `RpcCallScope`, new deadline timer — while the running handler keeps the old one; drain, deadline, client cancel and teardown then reach a token the handler does not hold, and the handler's own call scope is never closed.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart:817-819` routes every metadata-only frame
with a methodPath to `_handleMetadataMessage`, with no check that the stream is
already bound. There (`:944-947`):

```dart
state.setMethodKey(methodKey);
state.storeMetadata(message);          // _cachedContext = null
final context = _cacheContext(state, message);   // new token, scope, deadline
```

`responder_streams.dart:240-243` (`storeMetadata`) and `:51-62` (`armDeadline`
cancels the previous timer). For `_isPingMethodKey` the ping is answered again.

## Why it matters

Everything that stops a handler reads `state.cachedContext?.cancellationToken`:
`_abortActiveStreams`, `closeResponderResources`, `_runDrain`,
`_handleClientCancellation`, `_onDeadlineExceeded`. After one extra HEADERS frame
none of them reaches the handler's token, and the handler's `RpcCallScope` — where
it registered its cleanup via `context.callScope` — is orphaned: `_cleanupStream`
closes the NEW scope. A peer can therefore make a handler un-cancellable and leak
its disposers with a ~30-byte frame. The original deadline is also replaced by
whatever `grpc-timeout` the second frame carries (or none).

## Witness a round would build

Bidi method whose handler awaits `context.cancellationToken.cancelled` and
registers a disposer on `context.callScope`. Hand-built peer sends HEADERS, then
HEADERS again, then the endpoint is drained. Witness: handler never observes the
cancel; disposer never runs. Guard: without the second frame both happen.

## Fix sketch

Ignore a methodPath metadata frame for a stream that already has a method (or a
responder); at most read encoding hints from it. Never rebuild the context of a
dispatched stream.

## Owner decision

—
