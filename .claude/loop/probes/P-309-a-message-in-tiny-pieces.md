---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r836_fragments.dart
round: 836
commit: f8cc8234
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: stale (526c8d52)
promoted: packages/transport/rpc_dart_websocket/test/websocket_frame_guard_test.dart
---

# P-309 — a message in tiny pieces

## Measures

Two processes, both compiled. Websocket: `r836_server.dart` (an
`RpcWebSocketServer` over `rpcWebSocketConnections`, defaults, printing its
RSS) and `r836_fragments.dart <port> <n> <size>`: after the upgrade, one
binary message that never finishes, as `n` masked fragments of `size` bytes.
HTTP: `packages/transport/rpc_dart_http/.dart_tool/probe/r820_server.dart`
and `r836_chunks.dart <port> <n> <size>`: a POST whose chunked body is `n`
chunks of `size` bytes and never ends. Server RSS read in the server's own
process after the send.

```
  transport   n x size        wire        server RSS   closed
  websocket   1 x 2000000     1953 KiB    12 MiB       no    (control)
  websocket   2000000 x 1     13671 KiB   143 MiB      no    (max 185 MiB)
  http        1 x 2000000     1953 KiB    16 MiB       no    (control)
  http        2000000 x 1     11718 KiB   166 MiB      no
  after the fix:
  websocket   2000000 x 1     2048 KiB    12 MiB       yes, at fragment 4097
  websocket   4096 x 1        28 KiB      9 MiB        no
  http        2000000 x 1     11718 KiB   42 MiB       no
```

The channel layer, measured in one process with
`packages/core/rpc_dart/.dart_tool/probe/r836_tiny_data_frames.dart`
(one 2 MB gRPC message as 1-byte DATA frames over `RpcChannelTransport`):
+21 MiB against +6 MiB for one frame, the sender's own frames included.

## Control

The same bytes in one fragment or chunk: 12 and 16 MiB.
