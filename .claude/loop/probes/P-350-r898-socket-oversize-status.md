---
file: packages/transport/rpc_dart_socket/.dart_tool/probe/r898_oversize_status/probe.dart
round: 898
commit: 947f074c
paths: [packages/transport/rpc_dart_socket/lib/src/rpc_socket_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart]
status: stale (6967b453)
promoted: packages/transport/rpc_dart_socket/test/an_oversized_request_reads_resource_exhausted_test.dart
---

# P-350 — r898 socket oversize status

## Measures

A server-stream call over TCP whose request is past the server's 64 KiB
`maxMessageLengthBytes`, a new connection per call, N calls in a row against
one server; prints the count per status code, and the message of each one
that is not 8. Arguments: calls, request size in bytes. Before: 65537 B ->
8: 200 (also 200 under 8 busy CPU loops); 1 MiB -> 8: 66, 14: 34; 8 MiB ->
8: 12, 14: 88, every 14 "Write failed (OS Error: Broken pipe / Connection
reset by peer)". After: 100 of 100 at each of the three sizes; 48 MiB, past
the drain bound, 10 of 10.

The same file with the server and caller swapped sits under
`rpc_dart_websocket`, `rpc_dart_http` and `rpc_dart_http2`'s
`.dart_tool/probe/r898_oversize_status/`.

## Control

The siblings, unchanged code, 8 MiB: websocket 40 of 40 (and 40 of 40 at 64
KiB + 1 and 1 MiB), http 40 of 40, http2 40 of 40 read 8.
