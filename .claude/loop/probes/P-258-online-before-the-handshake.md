---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r753_online_before_ready.dart
round: 753
commit: 36a2241a
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-258 — online before the handshake

An `RpcClientConnection` with `maxAttempts: 4` and a 100 ms backoff, no
jitter, against a port that was free a moment ago. Run from the repo root:
`fvm dart run packages/transport/rpc_dart_websocket/.dart_tool/probe/r753_online_before_ready.dart <arm>`.

- `ctor`: the factory returns `RpcWebSocketCallerTransport(IOWebSocketChannel.connect(uri))`.
- `ready`: the same with `await channel.ready` first.

## Measures

Every state with its time, the number of Online events and factory calls,
the outcome and latency of one call made the moment Online arrives, and
uncaught errors under `runZonedGuarded`.

## Control

`ready` differs from `ctor` only in the awaited `ready`, and emits no Online,
so the bench separates the two.
