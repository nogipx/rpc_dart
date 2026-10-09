---
file: packages/core/rpc_dart_log/.dart_tool/probe/r763_unfinished_message.dart
round: 763
commit: bdb14fd3
paths: [packages/core/rpc_dart_log/lib/src/log_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
status: valid
---

# P-264 — an unfinished message to the log collector

## Measures

A raw client completes the WebSocket upgrade, then sends 1 MiB binary frames
with FIN clear, up to 256 MiB, never finishing the message. Printed: MiB the
server took before the connection ended, the process RSS growth, and how it
ended. Server and client share the process; the client reuses one buffer, so
the growth is the server's.

Arms (argv[0]): `collector` is `LogCollectorServer` as shipped; `library` is
`HttpServer` + `rpcWebSocketConnections` + `RpcWebSocketServer`.

## Control

The `library` arm, the same server with the transport's own upgrade: cut at
16-17 MiB. On macOS loopback the write after the cut sometimes stalls
instead of failing (netstat: the server's socket gone, the client's CLOSED
with 128 KiB queued), so every flush has a 3 s bound.
