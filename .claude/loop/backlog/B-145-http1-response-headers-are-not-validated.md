---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-145 — HTTP/1.1 caller passes response headers into metadata unchecked

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-low**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Core validates peer metadata in `_validateInbound`; the HTTP caller builds `RpcMetadata` from response headers with no count, size or character checks.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:433-476`.

## Why it matters

The security policy is one-directional on this transport.

## Witness a round would build

Response with 1000 headers or a CR in a value (raw server).

## Fix sketch

Run `validateMetadata` on the converted response metadata.

## Owner decision

—
