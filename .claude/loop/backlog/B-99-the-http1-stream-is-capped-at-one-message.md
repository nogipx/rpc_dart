---
status: closed (round 490)
round: 490
commit: a12a4209
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/core/rpc_dart/lib/src/core/parser.dart]
probe: P-129
reason: "closed — both ceilings CONFIRMED against a channel-pair control; the byte one is now raisable by the knob that names it and the doc states both"
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

## Closed (round 490) — both ceilings confirmed, and one was wired to the wrong knob

```
                       http                      channel (control)
1500 x 10 B      FAILED after 0 status=8       OK 1500
20 x 1 MiB       FAILED after 0 status=8       OK 20
100 x 10 B       OK 100                        OK 100

client-stream upload, 1500 x 10 B      status=8
client-stream upload, 4 x 1 MiB        got:4
```

**The sketch was narrowed by the measurement.** It asks for a separate
stream-level budget; both ceilings turned out to be raisable by knobs that
already exist, so a third would be new public surface for something
configuration solves. What was actually broken is that the BYTE ceiling was
wired to the wrong one: all three body sites bounded a whole body by
`maxFramedMessageBytes` (one message plus its prefix), so `maxBufferedBytes` —
"max buffered bytes for reassembly/parsing" — bounded nothing at all.

```
each knob raised alone, http           before      after
+maxBufferedBytes      20 x 1 MiB      FAILED      OK 20
+maxMessagesPerChunk   1500 x 10 B     OK 1500     OK 1500
```

The default is unchanged by construction: `effectiveMaxBufferedBytes` falls back
to `maxMessageLengthBytes + 5`, the same number, which is what keeps round 458's
message-at-exactly-the-limit working.

The class doc states both ceilings now, names the knob for each, and carries the
table above.

## Left open, deliberately

- **Chunk-by-chunk parsing.** It is the only way to lift the COUNT ceiling
  without raising a global knob, and it is a change to how the transport emits
  rather than a limit read from the wrong field. Needs its own bench.
- **The defaults.** A finite stream past them still fails rather than degrades.
  Raising either raises what one call may buffer on a transport that must hold
  the whole thing — a capacity decision, not a defect.
- **The ping-pong bidi.** *"blocks until its deadline because nothing is sent
  before `finishSending`"* is plausible from the wire format and was NOT
  measured; nothing in P-129 would see a hang.
