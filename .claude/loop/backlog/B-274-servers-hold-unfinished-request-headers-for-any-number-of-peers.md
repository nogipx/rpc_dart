---
status: awaiting owner
round: 782
commit: 5db1dd59
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/header_hold_attacker.py
reason: owner decision — a raw-connection cap and a header deadline are new defaults on public servers, and the alternative is a documented "deploy behind a proxy"
rank: 2
---

# B-274 — servers hold unfinished request headers for any number of peers

P-277: 300 unauthenticated connections, each sending a request line and
900 KiB of headers and never ending the block, hold +313 MiB (footprint
318 MB, unchanged at 110 s) on an `HttpServer` behind
`rpcWebSocketConnections`, and +311 MiB on `RpcHttpServer`. None is closed
after 140 s; `HttpServer.idleTimeout` does not cover a request whose headers
never end. dart:io caps one block (a non-stop stream is cut at about 3 MiB),
so the cost is linear in the attacker's bytes, about 1.2:1, with no bound on
the number of connections. RPC-18: dart:io buffers below every rpc_dart
limit, and `RpcWebSocketServer.maxConnections` counts upgraded channels, which
these never become.

The two cases differ in who owns the socket. `RpcHttpServer` binds its own
`HttpServer` (`shelf_io.serve`), so its defaults are rpc_dart's.
`rpcWebSocketConnections` is handed the application's `HttpServer`, and can
only document it.

Options for the owner:

1. `RpcHttpServer` binds a `ServerSocket` itself and serves through
   `HttpServer.listenOn` behind a wrapper that counts raw connections
   (a `maxConnections` default) and closes a socket whose first request has
   not arrived within a header deadline. A helper of the same shape for the
   websocket side, which the application may use instead of its own bind.
2. Document it: both servers are meant to sit behind a reverse proxy that
   bounds connections and header time, and say so in the READMEs and the
   skill.
3. Both: 2 now, 1 later.

## Owner decision

—
