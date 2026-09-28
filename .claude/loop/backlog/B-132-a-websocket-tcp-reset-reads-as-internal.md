---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-132 — websocket: a local connection reset surfaces as INTERNAL "closed by peer 1002"

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**low-medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Dart:io sets close code 1002 itself on a socket error (to verify on the SDK); 1002 is not in `saidNothing`, so the channel emits a non-retryable INTERNAL naming the peer; raw channel errors (`WebSocketChannelException` on web) are forwarded with no gRPC status at all.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart:31-36` (table), `:131-133` (raw `onError`),
`:149-164` (`onDone` mapping).

## Why it matters

The commonest network failure, a TCP reset, becomes INTERNAL (final) instead of
UNAVAILABLE (retryable).

## Witness a round would build

Kill the server process mid-call (RST) and read the caller's status; check
`WebSocket.closeCode` in dart:io's `_WebSocketImpl` for the error path.

## Fix sketch

Map local-error closes and raw channel errors to UNAVAILABLE.

## Owner decision

—
