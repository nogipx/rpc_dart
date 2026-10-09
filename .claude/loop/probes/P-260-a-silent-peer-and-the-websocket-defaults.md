---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r755_silent_peer.dart
round: 755
commit: 32dfde70
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart]
status: valid
---

# P-260 — a silent peer and the websocket defaults

A socket server that accepts TCP and never answers the upgrade. Run from the
repo root:
`fvm dart run packages/transport/rpc_dart_websocket/.dart_tool/probe/r755_silent_peer.dart <arm> [seconds]`.

- `default`: `connect(uri)`, the parameter OMITTED, 40 s cap.
- `null`: `connect(uri, connectTimeout: null)`, 40 s cap.
- `bounded`: `connectTimeout: 2 s`.
- `conn`: `RpcClientConnection` with a factory calling `connect(uri)` and
  its own defaults; states and accepted sockets after the given seconds.

## Measures

How `connect()` ends and when; for `conn`, the states with their times and
how many sockets the server accepted (one per attempt).

## Control

`bounded` refuses at 2 s, so the bench sees a bound when there is one.
`default` and `null` must be separate arms with a cap past the 30 s default:
an explicit null measures the opt-out, and a shorter cap reads the same with
and without a default (RPC-08, rounds 563 and 584).
