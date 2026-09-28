---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-135 — RpcWebSocketServer.start() during a draining stop()

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**low-medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`start()` sets `_isRunning = true` at once because `_connectionsSub` survives `stop()`; the still-running stop then closes connections accepted after the restart, and `_endpoints.clear()` drops ones added during the close loop without closing them.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart:194-203`.

## Why it matters

Leaked endpoints and dropped fresh connections on a quick restart.

## Witness a round would build

`stop(drainTimeout: 1s)` unawaited, `start()`, connect a client; is it served?

## Fix sketch

Serialise start/stop, or refuse start while stopping.

## Owner decision

—
