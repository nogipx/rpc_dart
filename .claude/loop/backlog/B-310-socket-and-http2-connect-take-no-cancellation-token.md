---
status: open
round: (not re-measured)
commit: b3350b20
paths: [packages/transport/rpc_dart_socket/lib/src/rpc_socket_connect.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: P-342
reason: risk — round 890 gave the websocket caller a cancellationToken; the socket and http2 callers have none, and their factory phase (TCP connect, proxy CONNECT, TLS) cannot be ended by a dispose
rank: 4
---

# B-310 — socket and http2 connect take no cancellation token

Round 890 closes a transport the factory already returned, which covers both
callers against a peer that accepts and stays silent (P-342: 0-12 ms after
dispose). What it cannot reach is work still inside their factory: a TCP
connect to a black hole (a SYN nobody answers), http2's proxy CONNECT, and the
TLS handshake (B-309). There `dispose()` leaves the socket to the transport's
own timeout, or to the OS with `connectTimeout: null`.

`RpcClientConnection.cancellable` already hands a token to the factory; the
callers need a `cancellationToken:` that ends those stages. For the socket
caller `Socket.startConnect` returns a `ConnectionTask` with `cancel()`.

## Next step

Measure the black-hole case: a connect to a non-routable address
(10.255.255.1), dispose() mid-connect, time to the socket's release (the
client process's descriptor count, L-21). Control: a refused port.

## Owner decision

—
