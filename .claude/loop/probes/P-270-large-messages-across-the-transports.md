---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r770_large_messages_parity.dart
round: 770
commit: 437f8ef3
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**]
status: valid
---

# P-270 — large messages across the transports

## Measures

For websocket, http2 and isolate, default policies: a server stream of N
messages of SIZE characters read throughout, the same paused 300 ms and
resumed, and a client-stream upload of N such messages. Printed per row:
received count and outcome (`done`, `error ...`, `STUCK` after 30 s).
argv[0] picks a transport or `all`; env N (3), SIZE (7000000).

## Control

The same rows on the other transports, which share the message limit
(16 MiB) and differ only in how they bound the un-consumed backlog.
