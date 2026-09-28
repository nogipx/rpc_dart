---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-136 — a plain HTTP request to the websocket server is logged as a connection error

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Every request goes to `WebSocketTransformer`, which answers 400 and errors the connections stream; each health check produces an error log and an `onConnectionError`.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart:90-102`, `rpc_websocket_server.dart:125-135`;
allowed origins are also re-normalised per handshake (`:124-126`).

## Why it matters

Error-level noise at the load balancer's probe rate.

## Witness a round would build

Ten GETs to the port; count error records.

## Fix sketch

Check `WebSocketTransformer.isUpgradeRequest` first and answer non-upgrades
directly; normalise origins once.

## Owner decision

—
