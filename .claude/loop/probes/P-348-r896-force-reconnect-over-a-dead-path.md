---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r896_force_reconnect/probe.dart
round: 896
commit: 99126bfa
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
promoted: no — CLEAN round, nothing to witness
---

# P-348 — r896 force reconnect over a dead path

## Measures

`forceReconnect()` on an `RpcClientConnection` that reaches a real server
through a TCP relay; in the `frozen` arm the relay stops forwarding the first
connection in both directions just before the call and keeps its sockets
open. Printed: ms from `forceReconnect()` to Online again and the states seen.
The same file, server and factory swapped, sits in
`rpc_dart_socket/.dart_tool/probe/r896_force_reconnect/` and
`rpc_dart_http2/.dart_tool/probe/r896_force_reconnect/`.

Core arm, `packages/core/rpc_dart/.dart_tool/probe/r896_detach_window/probe_test.dart`:
a fake transport whose `close()` takes 0 or 2000 ms; state and
`awaitReconnect()` 10 ms into the window, then a call through
`RpcRetryInterceptor()` defaults.

## Control

`live`: the relay keeps forwarding. websocket 12 ms, socket 7 ms, http2 15 ms
to Online; `frozen` 8, 5 and 8 ms. Core: close 0 ms, Online again at 0 ms.
