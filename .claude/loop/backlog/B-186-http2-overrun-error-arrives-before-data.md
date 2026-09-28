---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-186 — http2 caller: on a window overrun the error is delivered before the data that caused it

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**low**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`resetStream` runs synchronously only to its first await, so `_emit` delivers the overrunning message after the RESOURCE_EXHAUSTED error.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1545-1560`.

## Why it matters

Consumer sees error, then data.

## Witness a round would build

Peer overrunning the window by one frame.

## Fix sketch

Drop the message once the stream is refused.

## Owner decision

—
