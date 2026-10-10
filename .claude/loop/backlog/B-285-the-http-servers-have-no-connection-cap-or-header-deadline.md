---
status: open
round: 806
commit: 0b9d5a08
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_http/lib/src/peer_watch.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/header_hold_attacker.py
reason: owner decision — B-274's option 1, "later": a raw-connection cap and a header deadline are new defaults on public servers
release: changelog
rank: 9
---

# B-285 — the http servers have no connection cap or header deadline

The second half of the owner's B-274 decision (option 3: document now,
option 1 later). Round 806 wrote the documentation; this is the code.

P-277 (round 782): 300 connections, each holding a 900 KiB unfinished header
block, keep +313 MiB on an `HttpServer` behind `rpcWebSocketConnections` and
+311 MiB on `RpcHttpServer`, none closed after 140 s.

What round 804 changed here: `RpcHttpServer` now binds its own
`ServerSocket` and wraps every accepted socket (`PeerWatchingServerSocket`),
so the place to count raw connections and to arm a header deadline exists.
A first request's arrival is visible to it only through dart:io's
`HttpServer` stream, which is where the deadline would be cancelled.

Option 1 as B-274 put it: a `maxConnections` default on `RpcHttpServer` and
a socket closed if its first request has not arrived within a header
deadline; for the websocket side, a helper of the same shape the
application may bind instead of its own `HttpServer`. Both are new defaults
and new API; the values are the owner's.

## Owner decision

—
