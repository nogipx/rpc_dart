---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-190 — http2 responder: an unowned subscription, status-less endings, a lost parked trailer, a health that lies

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`incomingStreams.listen` is never stored or cancelled, so streams arriving during close register into cleared maps; `close()` and `releaseStreamId` end streams with an empty DATA END_STREAM and no trailers (the client synthesises retryable UNAVAILABLE); `_fcRefuseOverrun` sends its trailer unawaited and `endStreamNow` then drops it; `_closeForProtocolError` terminates without setting `_isClosed`, so `health()` says ready; `_closeIfDrained` and sequential cancels have no error handling.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart:144-171, 281, 326-331, 547-554, 830-834, 1040-1065, 1092-1138`;
`rpc_http2_common.dart:164, 195-199` (`endStreamNow` still waits on the window
while paused).

## Why it matters

Work registered after close; retryable status for work that ran; wrong health.

## Witness a round would build

Open a stream during the close window; release a stream mid-response and read
the client's status.

## Fix sketch

Own the subscription; send a trailer (UNAVAILABLE/CANCELLED) when ending a stream
early; mark closed on protocol error.

## Owner decision

—
