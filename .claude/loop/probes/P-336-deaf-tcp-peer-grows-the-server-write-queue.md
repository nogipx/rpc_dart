---
file: packages/transport/rpc_dart_socket/.dart_tool/probe/r881_deaf_peer_write_backlog.dart
round: 881
commit: ed6f6293
paths: [packages/transport/rpc_dart_socket/lib/src/rpc_socket_channel.dart, packages/transport/rpc_dart_socket/lib/src/rpc_socket_server.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
status: valid
promoted: packages/test/rpc_dart_conformance/test/i3_memory_per_peer_test.dart
---

# P-336 — a TCP peer that never reads keeps starting calls

`fvm dart <file> <arm> <calls>`. The server (RpcSocketServer on TCP, or
RpcWebSocketServer for `ws-*`) runs in this process with no contracts, so
every call is an unknown method answered at once with a trailer. The peer is
a child process. Arms: `raw-deaf` (RawSocket, read events off), `deaf`
(dart:io Socket, subscription paused), `reads`, `ws-deaf`, `ws-reads`.

## Measures

Bytes of answers that were waiting for the peer when it starts reading,
counted at the peer. Against the kernel's ceiling (4 MiB send + 4 MiB receive
on this macOS, `kern autosndbufmax/autorcvbufmax`), the rest was held by the
server. `raw-deaf` also reports whether the server stopped reading
(`STALLED`).

## Control

The mechanism removed is the server reading on while its writes are queued:
the same `raw-deaf` peer against the fixed server, and the canary that
switches the read pause off.

```
                         calls    written    waiting at resume   server rss peak
raw-deaf, before fix   200000   23046 KiB    59375 KiB             +174 MiB
raw-deaf, after fix    200000    2452 KiB     6318 KiB (STALLED)   +31 MiB
deaf (paused Socket)    20000    2304 KiB     5937 KiB
reads                   20000    2304 KiB        0 KiB
ws-deaf, unfixed       200000   23046 KiB    59375 KiB
```
