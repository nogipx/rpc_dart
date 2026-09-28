---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-134 — RpcWebSocketServer.stop() closes endpoints one at a time

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`for (final endpoint in List.of(_endpoints)) { await endpoint.close(); }` — each close awaits the socket close, and dart:io waits up to 5 s for a peer that does not answer the close, so N dead peers cost up to N x 5 s.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart:196-202`.

## Why it matters

Shutdown time linear in dead connections.

## Witness a round would build

20 half-open peers; time `stop()`.

## Fix sketch

`Future.wait` with per-endpoint error handling.

## Owner decision

—
