---
status: open
round: 906
commit: 642329a8
paths: [packages/core/rpc_dart/lib/src/integration/header_bounded_server_socket.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_http_server.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
probe: none
reason: risk — not measured: the server side of round 904/906's stage. A client that opens TCP to an HttpServer.bindSecure (websocket, http) and never sends a ClientHello may hold its accepted socket for as long as it likes; http2 has a witness for this (a_silent_tls_socket_is_dropped_test), websocket and http none
rank: 3
---

# B-316 — a tls server and a client that never says hello

Rounds 904 and 906 bounded the CLIENT's TLS handshake. The server's is the
same stage from the other side. `RpcHttp2Server` drops a socket silent through
its handshake (`a_silent_tls_socket_is_dropped_test.dart`). The websocket and
http servers run on dart:io `HttpServer`, and `RpcHeaderBoundedServerSocket`
bounds a request's header block from the accept; whether that bound covers a
TLS handshake that never starts depends on where the bounded socket sits
relative to the TLS layer, and nobody has measured it.

Pre-auth, peer-driven: if it holds, a peer opens N sockets and never says
hello, and each holds a descriptor until it leaves.

## Next step

`HttpServer.bindSecure` behind each server's documented setup, N raw TCP
clients that never write, count the SERVER process's open sockets at 5 s and
60 s (L-21). Control: the same N clients completing the handshake and
sending nothing.

## Owner decision

—
