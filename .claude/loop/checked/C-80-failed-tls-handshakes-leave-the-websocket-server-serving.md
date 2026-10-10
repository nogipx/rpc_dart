---
round: 831
commit: 30c93ba0
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
scope: RpcWebSocketServer over an application's HttpServer.bindSecure (self-signed), ten connections sending plaintext into TLS or a cut ClientHello; macOS; RpcHttpServer has no TLS of its own
---

# C-80 — failed TLS handshakes leave the websocket server serving

Network-audit KV-G-03, the TLS half (round 812 measured descriptor
exhaustion). Ten connections that fail the TLS handshake (plaintext HTTP into
the TLS port, or a ClientHello cut short and closed) leave the server
serving: an honest `wss` call answers, `onConnectionError` reports nothing
(dart:io drops a failed handshake before the HttpServer stream), and nothing
reaches the zone. Probe
`packages/transport/rpc_dart_websocket/.dart_tool/probe/r831_tls_handshake_errors.dart`
(certificate generated into `/tmp/r831`).

## Control

No failed handshake: the same honest call answers.
