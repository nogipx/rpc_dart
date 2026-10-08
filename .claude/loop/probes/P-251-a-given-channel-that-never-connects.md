---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r747_unconnected.dart
round: 747
commit: d4e8de6c
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: valid
---

# P-251 — a channel that never connects, given to the constructor

A port that was free a moment ago, so nothing listens. Each arm runs in
`runZonedGuarded` and counts uncaught errors. Run in
`packages/transport/rpc_dart_websocket` with
`fvm dart run .dart_tool/probe/r747_unconnected.dart <arm>`.

- `rpc`: `RpcWebSocketCallerTransport(IOWebSocketChannel.connect(dead))`,
  health right after construction and 2 s later.
- `bare`: the channel alone, stream listened with `onError`, `ready` never
  awaited.
- `ready`: `bare` with `ready` awaited in a try.

## Measures

Uncaught errors per arm; the transport's health level and `isClosed`.

## Control

`bare` and `ready` together, without rpc_dart: the uncaught error is
web_socket_channel's unobserved `ready`, and observing it removes it.
