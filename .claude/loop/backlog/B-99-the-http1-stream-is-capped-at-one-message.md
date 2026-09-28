---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/core/rpc_dart/lib/src/core/parser.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-99 — an HTTP/1.1 stream in either direction is capped at ONE message's size and 1024 messages

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The whole response body is bounded by `maxFramedMessageBytes` and parsed as one chunk (so `maxMessagesPerChunk = 1024` applies to the whole stream); the request body likewise, answered 413 — a server stream over 16 MiB total or 1024 items fails, contrary to the class doc.

## The shape

Caller `packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:197-222`, `_readBounded`:

```dart
final limit = _policy.maxFramedMessageBytes;
await for (final chunk in response.stream) {
  builder.add(chunk);
  if (builder.length > limit) throw RpcStatusException(resourceExhausted, ...);
}
```

Responder `rpc_http_responder_transport.dart:340-352` bounds the request body the
same way. The body then reaches `RpcMessageParser` as a single chunk, and
`parser.dart:299` refuses more than `maxMessagesPerChunk` messages in one chunk.
The class doc (`rpc_http_caller_transport.dart:72-76`) says finite server streams
succeed.

## Why it matters

A finite server stream of 2000 small items, or of 100 x 1 MiB items, fails with
RESOURCE_EXHAUSTED; a client-stream upload whose messages total more than one
message's limit gets 413. A ping-pong bidi (send, wait for a reply, send) blocks
until its deadline because nothing is sent before `finishSending`.

## Witness a round would build

Server stream of 1500 x 10-byte messages and of 20 x 1 MiB messages over
HTTP/1.1 with default policy; same over websocket as the control.

## Fix sketch

Bound the body by a separate stream-level budget (or by
`maxMessageLengthBytes * N`), feed the parser chunk by chunk, and correct the
class doc on what bidi and streaming mean over HTTP/1.1.

## Owner decision

—
