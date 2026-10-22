---
file: packages/transport/rpc_dart_socket/.dart_tool/probe/r899_oversize_response/probe.dart
round: 899
commit: 14f0ef47
paths: [packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/transport/rpc_dart_socket/lib/src/rpc_socket_channel.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
status: stale (6967b453)
promoted: packages/test/rpc_dart_conformance/test/i7_one_failure_one_status_test.dart
---

# P-351 — r899 oversize response

## Measures

A server-stream call whose RESPONSE is past the caller's 64 KiB
`maxMessageLengthBytes` (the server keeps the default), N calls, a new
connection per call; then `shared`: one connection, alternating an oversized
and an 8-byte response. Prints the count per status. The same file with the
server and caller swapped sits under `rpc_dart_websocket`, `rpc_dart_http` and
`rpc_dart_http2`'s `.dart_tool/probe/r899_oversize_response/`.

socket, websocket, http, http2 alike: 65537 B and 8 MiB -> 8: 30 of 30;
shared, 8 MiB -> big 8: 10, small ok: 10.

## Control

Round 898's request probe (P-350) on the same transports: the request
direction at 8 MiB read 14 on socket before its fix, so the method sees a
reset when there is one.
