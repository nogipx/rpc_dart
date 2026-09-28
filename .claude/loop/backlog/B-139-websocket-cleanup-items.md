---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_stub.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_responder_transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-139 — websocket: smaller defects and hygiene

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Close order, dead table rows, a duplicated annotation, headers captured once, an analyzer workaround, duplicated server branches, an ignored callback, a dropped parameter, no connection cap, an unhandled close future, a pure forwarder.

## The shape

1. `rpc_websocket_channel.dart:242-244` — `close()` cancels the read subscription
   before `sink.close()`; dart:io then cannot read the peer's close reply and
   (unverified) falls back to its 5 s timer.
2. `rpc_websocket_channel.dart:31-32` — rows for null/1000/1001/1005/1006 are
   unreachable; `saidNothing` filters them first.
3. `websocket_caller_transport.dart:465-471` — `@override` twice on
   `sendDirectObject`.
4. `websocket_caller_transport.dart:287-294` — `connect()` captures `headers` once
   for every reconnect; an expiring token cannot be refreshed.
5. `ws_open_stub.dart:61` — `final _ = (pingInterval, enableCompression, headers);`
   allocates a record to silence the analyzer.
6. `rpc_websocket_server.dart:339-367` — peer and responder branches duplicate
   creation and `sink.done` wiring; `onEndpointCreated` is silently ignored when
   `onPeerEndpointCreated` is set; `createWithContracts` drops `logController`; no
   cap on connections; `channel.sink.close()` at `:380` is neither awaited nor
   given an error handler.
7. `websocket_responder_transport.dart` — forwards every member to
   `RpcChannelTransport`, hiding any capability core adds later (its own doc names
   the risk); a factory returning the channel transport avoids it.

## Why it matters

Small, but items 1 and 6's unhandled future are behaviour, not style.

## Witness a round would build

Item 1: time a clean close against a well-behaved peer.

## Fix sketch

One commit per item group.

## Owner decision

—
