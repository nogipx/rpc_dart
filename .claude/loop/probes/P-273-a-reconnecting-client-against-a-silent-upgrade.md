---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r773_documented_factory_hangs.dart
round: 773
commit: 6bd85a09
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-273 — a reconnecting client against a silent upgrade

## Measures

`RpcClientConnection` with the factory from its own dartdoc
(`WebSocketChannel.connect(uri); await ch.ready;`), `maxAttempts: 1`,
against a TCP server that accepts, reads the upgrade request and never
answers. Printed: every state with its time, after WAIT seconds (env, 40).

## Control

The `bounded` arm: the same factory with `connectTimeout: 2 s`.
