---
status: closed (round 904)
round: 904
commit: b3350b20
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport_dial.dart]
probe: P-342
reason: risk — one P-342 run in round 890: secureConnect to a peer that accepts TCP and never answers TLS is still open at 40 s with default 30 s timeouts; not traced to its cause
rank: 3
---

# B-309 — http2 TLS handshake outlives connectTimeout

P-342 (`MODE=tls`): `RpcClientConnection` over
`RpcHttp2CallerTransport.secureConnect`, a listener that accepts TCP and never
writes, `dispose()` at 200 ms. The socket is still open 40 s later, though both
the connection's and the transport's `connectTimeout` are 30 s. The plain
`connect` (no TLS) closed at 29.8 s in the same probe with round 890's
readiness race switched off, so its timeout does end its stage; the suspect is the
TLS handshake: `SecureSocket.connect(timeout:)` may bound only the TCP connect.

If so, it is not only a dispose problem: every attempt that times out in the
handshake leaves its socket open, one per reconnect attempt.

## Next step

Measure without dispose: one attempt, `connectTimeout` 1 s, count the
listener's open sockets at 5 s and 60 s; then a reconnect loop of N attempts
and count again (L-21). Control: a listener that completes TLS. Find where
the handshake is awaited and whether anything owns the socket to destroy it.

## Closed

Round 904: `SecureSocket.connect(timeout:)` bounds only `RawSocket.connect`
(SDK source); the handshake had no bound and no handle to close. P-353: h2
pending at 8 s and its socket open at 23 s, then 1011 ms UNAVAILABLE and closed
at 1012 ms. The same mechanism in wss and https is B-314.

## Owner decision

—
