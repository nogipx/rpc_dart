---
status: closed (round 905)
round: 905
commit: b3350b20
paths: [packages/transport/rpc_dart_socket/lib/src/rpc_socket_connect.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: P-342
reason: risk — round 890 gave the websocket caller a cancellationToken and round 897 the socket caller (P-349: dispose mid-connect held the process 3.5-19.6 s); the http2 caller still has none, and its factory phase (TCP connect, proxy CONNECT, TLS) cannot be ended by a dispose
rank: 3
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

## Closed

The socket half by round 897. The http2 half by round 905: `connect` and
`secureConnect` take `cancellationToken`, which ends every stage of the open.
P-355, dispose 200 ms into the attempt: direct TLS open 15003 ms after dispose
-> closed 2 ms; proxy CONNECT 15002 ms -> 6 ms. The isolate spawn is B-315.

## Owner decision

—
