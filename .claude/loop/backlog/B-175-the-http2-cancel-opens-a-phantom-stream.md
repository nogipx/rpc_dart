---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-175 — http2 caller: a cancel for an unknown id opens a new /Unknown/Unknown stream

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`resetStream` returns false for an id not in `_activeStreams` (finished, cleared by reconnect, reserved but never opened); core then falls back to `sendMetadata(endStream: true)`, and `sendMetadata` always calls `makeRequest` with `methodPath ?? '/Unknown/Unknown'`; a second `sendMetadata` on a live id overwrites the stream and its subscription.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:809, 876-905`.

## Why it matters

Same class as the HTTP/1.1 phantom POST, on narrower windows.

## Witness a round would build

Server-stream call cancelled before its initial metadata goes out; count streams
at the server.

## Fix sketch

Refuse `sendMetadata` without a methodPath on an id with no stream; guard the
overwrite.

## Owner decision

—
