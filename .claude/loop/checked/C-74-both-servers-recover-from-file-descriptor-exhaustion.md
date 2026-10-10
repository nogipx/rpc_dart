---
round: 812
commit: 1580403e
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_http/lib/src/peer_watch.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
scope: RpcHttpServer and RpcWebSocketServer over rpcWebSocketConnections, defaults, macOS, a process limited to 128 descriptors and 300 idle connections; not TLS, not http2
---

# C-74 — both servers recover from file descriptor exhaustion

Network-audit KV-WS-05 (d), the class of CVE-2023-4785 (gRPC C-core did not
handle fd exhaustion on accept). Past the limit both servers refuse new
calls, which is the OS's limit; once the idle connections are released
both serve again within ~2.6 s, and the process logs no uncaught error: the
accept loops survive EMFILE. Bench `../probes/P-298-a-server-past-its-file-descriptor-limit.md`.

## Control

The honest call with no idle connections succeeds at once on both; the
recovery time matches the macOS close-detection delay measured in P-295.
