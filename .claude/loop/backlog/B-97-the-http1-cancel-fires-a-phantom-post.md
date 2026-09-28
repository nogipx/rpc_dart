---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-97 — cancelling a call over HTTP/1.1 sends a brand-new POST to /Unknown/Unknown

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The HTTP caller has no `IRpcStreamReset`, so core's cancel falls back to `sendMetadata(endStream: true)`; `_pending` is already empty once the request fired, so `sendMetadata` creates a new pending call with path `/Unknown/Unknown` and fires it — the server answers UNIMPLEMENTED and the real handler is never cancelled.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:291-298`:

```dart
final methodPath = metadata.methodPath ?? '/Unknown/Unknown';
_pending[streamId] = _PendingCall(methodPath: methodPath, requestHeaders: ...);
if (endStream) {
  await _fireRequest(streamId);
}
```

`_fireRequest` (`:318`) removed the original entry when the request went out.
Core's `_notifyPeerOfCancellation` (`base_processor.dart:77-136`) tries
`IRpcStreamReset` first — this transport does not implement it — then sends
`{x-client-cancelled: true, x-cancellation-reason, grpc-status: 1}` with
`endStream: true`.

## Why it matters

Every ordinary cancel of an in-flight unary call (token, `cancelRequest`,
`cancelMethod`) costs a second HTTP request that the server logs as an
unregistered method, while the first request's handler runs to completion. In a
browser the extra request also triggers a failing CORS preflight:
`x-client-cancelled` and `x-cancellation-reason` are not in
`_requiredGrpcAllowedHeaders`.

## Witness a round would build

HTTP server with a counting middleware; a unary handler parked for 2 s; cancel
the caller's token at 100 ms. Count requests reaching the server and their paths.
Expected today: 2, the second `/Unknown/Unknown`.

## Fix sketch

`sendMetadata` with `endStream` and no pending call: return (nothing to send). For
real cancellation implement `IRpcStreamReset` by aborting the in-flight request
(`http` 1.6's `AbortableRequest`, see B-lead on abandoned calls).

## Owner decision

—
