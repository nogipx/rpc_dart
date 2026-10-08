---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r748_flap.dart
round: 748
commit: 3fc2fa74
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-252 — RpcClientConnection against a server that accepts and refuses

`refuse`: `RpcWebSocketServer(maxConnections: 0)`, so every upgrade succeeds
and the server then closes the connection. `down`: nothing listening.
Backoff 200 ms doubling, no jitter, `maxAttempts: 4`, 6 s. Run in
`packages/transport/rpc_dart_websocket` with
`fvm dart run .dart_tool/probe/r748_flap.dart <arm>`.

## Measures

Factory calls, Online states, and whether and when the connection gives up.

## Control

`down`: the same client against a dead port gives up after 4 attempts.
