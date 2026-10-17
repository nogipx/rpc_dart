---
status: closed (round 885)
round: 881
commit: ed6f6293
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
probe: packages/transport/rpc_dart_socket/.dart_tool/probe/r881_deaf_peer_write_backlog.dart (P-336, arm ws-deaf)
reason: cost — the fix needs the dart:io WebSocket under the channel, which the server's public connection type hides
rank: 1
---

# B-300 — the websocket server writes with no bound on what the peer has not read

Measured in round 881 (lens RPC-18, bench P-336). A websocket peer that pauses
its subscription (dart:io then stops reading the socket) and keeps starting
calls that are answered with a trailer alone: 200000 calls, 23046 KiB sent,
0 KiB received while paused, 59375 KiB delivered on resume. The kernel holds
at most 8192 KiB, so the server held about 50 MiB, linear in the calls. The
matrix row `I-3 a peer that never reads is not answered without bound |
websocket` reads 99500 of 100000 calls taken against a bound of 60000; it is
KNOWN FAILING under this id.

Mechanism: `RpcWebSocketChannel.send` calls `WebSocketSink.add` and returns,
and nothing ties the read side to the write backlog. Round 881 fixed the same
shape on `RpcSocketChannel` by writing through `Socket.addStream` from a
controller it counts, and pausing reads past 1 MiB unsent.

Why that fix does not carry over: web_socket_channel 3.x builds
`IOWebSocketChannel` on `AdapterWebSocketChannel`, whose sink feeds a
`StreamChannelController` drained into `package:web_socket`'s `sendBytes`,
which calls dart:io `WebSocket.add`. No layer passes the dart:io backpressure
up, so `sink.addStream` on the channel sees none. dart:io's own
`WebSocket.addStream` does (its consumer pauses the source while the socket is
full), but `rpcWebSocketConnections` yields `Stream<WebSocketChannel>` and the
dart:io socket is no longer reachable once wrapped. A fix needs either a
`WebSocketChannel` of our own over the dart:io socket, or the server taking the
dart:io `WebSocket` itself. Both change what the server accepts.

What bounds it in time today, read in the SDK and not measured: dart:io
closes a socket whose ping got no pong within two `pingInterval`s (60 s by
default; only a pong resets the timer, `_http/websocket_impl.dart` 1248-1250
and 1314-1333). The 26 s run never reached it. A peer that reads just enough
to answer each ping is not closed by it, and is the case to measure.

## Closed by round 885

Re-measured with P-336 arm `ws-raw-deaf`: 60546 KiB waiting for 200000 calls,
121093 KiB for 400000. Fixed below dart:io, as the owner chose: the bounded
upgrade's `_BoundedSocket` writes through a counted controller and stops
reading past 1 MiB unsent, resuming at half. After: the peer stalls at
2493 KiB, 6233 KiB waiting; the websocket cell of the I-3 row is green. The
time bound stopped mattering for memory: what the server holds is bounded
however long the peer stays (the keepalive's effect on a paused peer was not
measured). Still unbounded,
and documented: compression on, a foreign `Stream<WebSocketChannel>`, the
client. `../rounds/885-a-deaf-websocket-peer-and-the-server-write-queue.md`.

## Owner decision

Fix below dart:io inside `_BoundedSocket`, server side only, no public API
change (2026-10-17).
