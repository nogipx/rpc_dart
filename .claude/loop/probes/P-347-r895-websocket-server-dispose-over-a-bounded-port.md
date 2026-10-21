---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r895_dispose_server/probe.dart
round: 895
commit: 24d08d7e
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_http_server.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
status: valid
promoted: packages/transport/rpc_dart_websocket/test/dispose_releases_a_bounded_port_test.dart
---

# P-347 — r895 websocket server dispose over a bounded port

## Measures

An `RpcWebSocketServer` set up as the README's `serve()` does, the HttpServer
not kept, then `dispose()`: whether a TCP connect to the port still succeeds,
and (via `run.py`, which reads lines on a thread and kills at 40 s) how long
the process lives after it. Arms: `idle` (no client) and `pending` (a client
that sent half an upgrade request) over `bindRpcWebSocketHttpServer`.
Before: port still accepting, process still running 38 s after dispose (killed)
in both. After: port released, exit in 14 ms (`idle`).

## Control

`plain`: the same over `HttpServer.bind`: port released, exit in 35-44 ms,
before and after.
