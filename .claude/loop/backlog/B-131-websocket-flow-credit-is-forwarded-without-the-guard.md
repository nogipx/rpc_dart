---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-131 — websocket caller forwards flow-control and per-stream reads without `_liveHere`

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`deferFlowCredit`, `returnFlowCredit` and `getMessagesForStream` go straight to the current `_inner`; in peer mode the server's ids restart at 2 on every socket, so a late `returnFlowCredit(2, n)` from the old connection credits the new stream 2.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:376-404`.

## Why it matters

Over-states a live stream's window by what a dead stream consumed.

## Witness a round would build

Peer mode, reconnect with a client-stream handler mid-consumption on the old
socket; read the new stream's credit.

## Fix sketch

Apply the same `_liveHere` guard as the send paths.

## Owner decision

—
