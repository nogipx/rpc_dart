---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r746_drop.dart
round: 746
commit: f8dd6a88
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-250 — does RpcClientConnection come back after a server restart?

An `RpcClientConnection` whose factory calls the transport's `connect()`. The
server stops, the probe prints the connection state, `isClosed` and
`health()` every 500 ms, makes one call, then starts a new server on the same
port and calls again. Arms in the websocket file: `conn`, `direct` (the bare
transport), `nofactory` (a transport built by the constructor, which closes on
a drop). The http2 file `rpc_dart_http2/.dart_tool/probe/r746_drop.dart` runs
the `conn` arm with a 50-200 ms backoff and the connection's logger on.

## Measures

The connection state after the stop, and the result of a call after the
restart.

## Control

`nofactory`: the same connection over a transport that closes its message
stream on a drop goes Offline at once. It isolates the mechanism to the stream
kept open.
