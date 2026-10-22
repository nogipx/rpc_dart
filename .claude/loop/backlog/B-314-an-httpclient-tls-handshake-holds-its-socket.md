---
status: open
round: 904
commit: 66cabcb3
paths: [packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: P-353
reason: risk — measured in round 904: against a peer that accepts TCP and never answers TLS, the wss connect and the https call END on time but each leaves its socket open; no public dart:io way to close it was found
rank: 2
---

# B-314 — an httpclient tls handshake holds its socket

P-353, 1 s connectTimeout / deadline, a listener that accepts TCP and never
writes:

```
arm=ws     returned=1029 ms  socket=closed at 1029 ms
arm=wss    returned=1003 ms  socket=OPEN at 16006 ms
arm=http   returned=1033 ms  socket=closed at 1034 ms
arm=https  returned=1003 ms  socket=OPEN at 16006 ms
```

Both go through dart:io's `HttpClient`, which connects https with
`SecureSocket.startConnect`. On `connectionTimeout` it calls
`ConnectionTask.cancel()`, and that cancels only the TCP connect
(`RawSecureSocket.startConnect` hands the raw task's `_onCancel` to the TLS
task). `close(force: true)` reaches only sockets the client already holds. So
the socket stays open for as long as the peer keeps it: one per reconnect
attempt, or per call on http.

Round 904 fixed the same mechanism in http2, which owns its socket, with
`RawSocket` + `RawSecureSocket.secure` + `RawSocketPipe`. Here the caller needs
a `Socket` (`WebSocket.fromUpgradedSocket`, an `HttpClient.connectionFactory`
for https), and a `RawSecureSocket` cannot be turned into one through public
API.

## Next step

Look for a way to close the handshake's socket under HttpClient before
building one: a `connectionFactory` that returns a `Socket` of its own, or a
`Socket` implementation over `RawSecureSocket` the way `RawSocketPipe` does
for http2. Count it per attempt in a reconnect loop (L-21).

## Owner decision

—
