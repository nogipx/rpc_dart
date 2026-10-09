---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r761_reconnect_twice.dart
round: 761
commit: 639e93c9
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart]
status: valid
---

# P-263 — reconnect through a failure, twice

`RpcWebSocketCallerTransport.connect` with its defaults against a real
`RpcWebSocketServer`. Twice: stop the server, `reconnect()` (which fails),
a call; start a server on the same port, `reconnect()`, a call, `health()`.
Every reconnect opens through `connectBounded` with the 30 s default
`connectTimeout`. Run from the repo root:
`fvm dart run packages/transport/rpc_dart_websocket/.dart_tool/probe/r761_reconnect_twice.dart`.

## Measures

The level `reconnect()` returns, the call's outcome and `health()` in each
phase of each cycle.

## Control

The down phase is the control for the up phase: with the server gone the
same calls read `unhealthy` and status 14, so a reconnect that failed to
recover would read the same way in the up phase.
