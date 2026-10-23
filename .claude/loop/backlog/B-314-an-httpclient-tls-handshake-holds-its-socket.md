---
status: open
round: 906
commit: 642329a8
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: P-353
reason: risk — measured in round 904 (P-353 https arm): an https call to a peer that accepts TCP and never answers TLS ends at its deadline and leaves its socket open; round 906 fixed the websocket half with RpcSecureSocket, the http half needs more than the factory
rank: 2
---

# B-314 — an httpclient tls handshake holds its socket

P-353, 1 s deadline, a listener that accepts TCP and never writes:

```
arm=http   returned=1033 ms (1 s deadline)  socket=closed at 1034 ms
arm=https  returned=1003 ms (1 s deadline)  socket=OPEN at 16006 ms
```

dart:io's `SecureSocket.startConnect` cancels only the TCP connect, so nothing
can close a socket still in the handshake. Round 906 added
`RpcSecureSocket.startConnect` (`package:rpc_dart/transport_io.dart`), whose
cancel also closes that socket, and the websocket caller uses it through
`HttpClient.connectionFactory`: P-356 wss 25 open sockets after 15 s of
reconnects -> at most 1.

The http caller is left, and the factory alone does not fix it:

- its default client is `http.Client()`, an `IOClient` over an `HttpClient`
  with no `connectionTimeout`, so nothing ever cancels the task: the call's
  deadline abandons the await and the connect runs on;
- a client the user passes in (the dartdoc's own example sets a
  `SecurityContext`) cannot be given a factory without losing that context.

So it needs a connect bound on the default client (a new default, as the
other callers have), a cancel from the call's deadline into the pending
connect, and a decision about user-supplied clients.

## Next step

Measure what the default client leaks per call against a silent TLS peer (one
socket per call, held for as long as the peer holds it). Then decide with the
owner: a `connectTimeout` on `RpcHttpCallerTransport` that builds its default
client with `RpcSecureSocket`, leaving a passed-in client as the user
configured it.

## Owner decision

—
