---
status: closed (round 838)
round: 811
commit: 68023a57
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/header_hold_attacker.py
reason: "FIXED in round 838 as decided: bindRpcWebSocketHttpServer, with its own copy of the watcher. Previously: cost — rpcWebSocketConnections is handed the application's HttpServer, so the bound needs a helper that binds the socket for it"
release: changelog
---

# B-287 — the websocket server's header block is the application's

Round 811 bounded an unfinished request header block on `RpcHttpServer`
(bytes from the policy, `headerTimeout`, `maxConnections`), because that
server binds its own socket. `rpcWebSocketConnections` is handed the
APPLICATION's `HttpServer`; P-277 measured the same +313 MiB for 300 x 900
KiB there (round 782), and nothing in rpc_dart sees those bytes.

A FINISHED block is bounded only by dart:io too: P-299 (round 813) got 101
for 100 000 headers (1.29 MB on the wire), and the connection closed only
past dart:io's 1 MiB `_headerTotalSizeLimit`, which counts name and value
bytes, about 1.4 MB on the wire. The http server answers 400 at the
policy's header count.

The way B-274's option 1 put it: a helper of the same shape the
application may bind instead of its own `HttpServer` (it can reuse
`PeerWatchingServerSocket`, now in rpc_dart_http, if it moves to a place
both packages can import). Until then the websocket README tells the
application to put a proxy in front.

## Owner decision

Owner, 2026-10-11: a copy of the watcher in rpc_dart_websocket, and a helper
that binds the socket, rather than a shared package or a dependency on
rpc_dart_http.
