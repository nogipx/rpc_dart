---
round: 788
commit: 6bf688cd
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart]
scope: RFC 6455 conformance of rpc_dart's websocket accept path and its bounded connect, by the Autobahn TestSuite minus 9.*, 12.*, 13.*; not the RPC layer above the channel
---

# C-70 — the websocket paths add no conformance failures

Autobahn's 247 cases against rpc_dart's own accept path
(`rpcWebSocketConnections`, defaults: the bounded upgrade and its frame guard
in front of dart:io) and against its bounded connect (`openWebSocket` with
`maxMessageBytes`), each beside the same echo on bare dart:io (P-282).

The server results are identical to bare io case by case. The client's are
the same seven FAILED; it is stricter than bare io on two cases and differs
on one, 2.5: an oversized ping fails the connection without a 1002 Close
frame. The connection ends either way, so it is a conformance detail below
the severity bar, not a defect worth a round.

The seven FAILED belong to dart:io: 5.19 says a pong waits behind an
unfinished fragmented message, which would delay a peer's keepalive while it
dribbles one large message.

Re-open if the frame guard or `connectBounded` changes, or to run 12.* and
13.* if compression is ever turned on by default.

## Control

The bare dart:io agents, same suite, same echo: the server column matches
the rpc_dart one exactly.
