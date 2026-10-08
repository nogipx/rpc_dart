---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r749_inflight.dart
round: 749
commit: bdbfc742
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-253 — calls in flight when the server stops

A server stream whose handler yields once and then waits for ever, and a
unary call whose handler never answers. Once the first item has arrived, the
server stops. The probe reports how each call ends at the client and when.
The same file exists in `rpc_dart_http2/.dart_tool/probe/`. Arms: `bare`
(the transport from `connect()`) and `conn` (behind `RpcClientConnection`).
Run in each package with `fvm dart run .dart_tool/probe/r749_inflight.dart <arm>`.

## Measures

Per call: the status it ends with and the time after the stop, or STILL OPEN
at 10 s.

## Control

The first item arriving on the server stream: the call is live when the
server stops.
