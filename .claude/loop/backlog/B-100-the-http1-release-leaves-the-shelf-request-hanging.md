---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-100 — releaseStreamId on the HTTP/1.1 responder drops the pending call without answering it

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`releaseStreamId` removes `_pending[id]` and never completes its completer; the deadline reclaim (`_onDeadlineExceeded` → `_cleanupStream`) deliberately sends no trailer, so the shelf handler awaits a future that never completes and the HTTP response is never written.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:440-443`:

```dart
bool releaseStreamId(int streamId) {
  _pending.remove(streamId);
  return _idManager.releaseId(streamId);
}
```

The shelf handler returns `pending.completer.future` (`:422`). The reclaim path:
`responder_pipeline.dart:2089-2112` cancels the token and, 2 s later, calls
`_cleanupStream` without a trailer ("Deliberately does NOT answer with a
DEADLINE_EXCEEDED trailer"). A late `sendMetadata` then finds no pending call and
only logs (`:452-458`).

## Why it matters

Every call whose handler ignores its token past the deadline leaves a shelf
request pending forever: the connection stays open until the client gives up,
and the request object and handler closure stay reachable after that. `health()`
counts `_pending`, so the drain reads zero while those responses are unwritten.

## Witness a round would build

Unary handler that ignores cancellation and sleeps 10 s; caller deadline 500 ms.
After 3 s: does the server-side request future complete? Expected today: no.

## Fix sketch

Complete the completer in `releaseStreamId` (a 200 with `grpc-status` 4/1, or a
503) when it is still pending.

## Owner decision

—
