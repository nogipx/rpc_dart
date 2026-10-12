---
round: 842
commit: 4c753983
paths: [packages/transport/rpc_dart_http/lib/src/peer_watch.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
scope: RpcHttpServer(maxConnections: 1); clients that send a request and read the answer, or connect and send nothing, then exit (nc processes); macOS, read 3.5 s after the last exit
---

# C-81 — an http connection returns its slot when the client leaves

`RpcHttpServer`'s `maxConnections` slot comes back when a kept-alive or
silent client leaves: three such clients at a cap of 1, then a fresh request
is served, and the server holds no socket on the port. Bench
`../probes/P-313-a-client-process-leaves-a-capped-http-server.md`.

Read the server no sooner than 2.5 s after the client leaves (L-25): before
that every arm reads REFUSED here, from the delay alone.

## Control

`_onEnded()` ablated in `_WatchedSocket._ended`: REFUSED in both arms, with
no socket left on the server.
