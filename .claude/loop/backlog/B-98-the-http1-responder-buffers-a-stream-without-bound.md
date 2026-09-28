---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-98 — the HTTP/1.1 responder buffers a streaming response with no ceiling

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`sendMessage` appends every response frame to `pending.bodyBuffer` until end-of-stream and nothing caps it, so any client calling an unbounded server-stream method grows server memory for as long as the handler produces — while the caller will refuse any body over one message anyway.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:469-486`:

```dart
pending.bodyBuffer.add(data);
if (endStream) {
  await _flushResponse(streamId);
}
```

## Why it matters

Memory DoS reachable by any client: open a server-stream call on a method that
streams until cancelled (subscriptions, tails, feeds). HTTP/1.1 cannot flush
before the end, so the handler's whole output is resident. The caller rejects the
body once it passes `maxFramedMessageBytes` (see the lead on one-message bodies),
so everything past that point is buffered for nothing.

## Witness a round would build

Server-stream handler emitting 64 KiB messages forever over `RpcHttpServer`;
sample RSS at 1 s intervals for 10 s. Expected: linear growth.

## Fix sketch

Fail the stream (RESOURCE_EXHAUSTED trailer, cancel the handler token) once the
buffer exceeds the caller-side ceiling; document that HTTP/1.1 server streams are
bounded.

## Owner decision

—
