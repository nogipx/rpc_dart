---
status: closed (round 890)
round: 890
commit: acade03e
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: P-341
reason: closed — CONFIRMED in round 890 (P-341: 29.8 s after dispose with default timeouts, still open at 60 s with none) and fixed there: RpcClientConnection.cancellable plus the websocket cancellationToken, and a transport not yet ready is closed on a stop. Socket and http2 factory stages remain: B-309, B-310
rank: 6
---

# B-305 — dispose leaves a pending connect open

`RpcClientConnection.dispose()` sets the stop flags, closes the proxy and
returns. It does not reach a factory call still in flight. When that call is
a websocket connect to a peer that accepted TCP and never answers the
handshake, its socket stays open until the factory settles: the transport's
own `connectTimeout` (30 s by default) or the connection's connect bound,
whichever is shorter. A transport the factory returns after `dispose()` is
closed, so this is a bounded delay, not a leak -- but an app that disposes
on shutdown holds the socket past its own exit path.

## Next step

Measure: a TCP listener that accepts and never writes, a connection over
`RpcWebSocketCallerTransport.connect`, `connect()`, then `dispose()` while the
handshake is pending. Count the listener's open sockets after `dispose()`
returns and over time (L-21: count the socket in the process that owns it).
Control: the same with a peer that answers the handshake. Check the http2
and socket callers the same way (L-18).

## Owner decision

—
