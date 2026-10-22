---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r890_dispose/probe.dart
round: 890
commit: b3350b20
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart]
status: stale (6967b453)
promoted: packages/transport/rpc_dart_websocket/test/a_cancelled_connect_closes_its_socket_test.dart
---

# P-341 — r890 websocket dispose mid connect

## Measures

Milliseconds from `RpcClientConnection.dispose()` to a raw listener seeing the
client's socket end, when the listener accepted TCP and never answers the
upgrade. Arms: plain constructor with default timeouts; plain with both
`connectTimeout: null` (`MODE=unbounded`); `.cancellable` passing the token to
`connect(cancellationToken:)`, with and without timeouts. Before the fix:
29802 ms, and still open at 60 s unbounded. After, cancellable: 0-8 ms.

## Control

The same listener forwarding to a real websocket server, dispose() after
Online: 4-10 ms on every run.
