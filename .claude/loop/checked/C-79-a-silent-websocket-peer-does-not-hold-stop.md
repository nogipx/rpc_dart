---
round: 826
commit: 990094e9
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_responder_transport.dart]
scope: RpcWebSocketServer over rpcWebSocketConnections, stop() without a drain, up to five peers that completed the upgrade and then stopped reading; not stop(drainTimeout), not TLS
---

# C-79 — a silent websocket peer does not hold stop()

Network-audit KV-WS-06 (a close handshake that never ends), server side.
Peers that complete the upgrade and then never read, so never answer the
server's close frame, do not hold `RpcWebSocketServer.stop()`: it returns in
7-19 ms with one to five of them, as with none (9 ms). Probe
`packages/transport/rpc_dart_websocket/.dart_tool/probe/r826_stop_silent_peer.dart`.

The caller side of the same shape was round 800 (B-277).

## Control

No silent peer: 9 ms.
