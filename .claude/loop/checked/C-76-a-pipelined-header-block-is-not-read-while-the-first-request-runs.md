---
round: 820
commit: 16b052a6
paths: [packages/transport/rpc_dart_http/lib/src/peer_watch.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
scope: RpcHttpServer on defaults, macOS, a complete request to a slow method followed on the same connection by an unfinished header block of up to 20 MB; not TLS
---

# C-76 — a pipelined header block is not read while the first request runs

Round 811's header bound (`PeerWatchingServerSocket`) counts a block only
from the response of the request before it, so a block pipelined behind a
slow request is not counted while that request runs. That is not a hole:
dart:io stops reading the connection until the response is written, so the
block waits in the kernel's socket buffer, and the server's RSS does not
move (9 MiB against 11 MiB with 10.6 MB accepted by the kernel). Once the
response is written the watcher counts what follows. Bench
`../probes/P-303-a-pipelined-request-behind-a-slow-one.md`.

Re-open if dart:io starts reading pipelined requests ahead (a dart:io
upgrade), or if the server moves off `HttpServer.listenOn`.

## Control

The same block as the connection's first request: closed by the bound, the
same server RSS.
