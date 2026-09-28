---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-187 — http2 caller and responder: close() sleeps a fixed 50 ms

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`await Future<void>.delayed(Duration(milliseconds: 50))` before resetting every stream; the comment below it says waiting cannot rescue a call.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1916-1924, 1928-1935`;
`rpc_http2_responder_transport.dart:1083-1090`.

## Why it matters

Dead latency on every close with streams open, multiplied by the serial server
stop.

## Witness a round would build

Time `close()` with one open stream.

## Fix sketch

Remove it.

## Owner decision

—
