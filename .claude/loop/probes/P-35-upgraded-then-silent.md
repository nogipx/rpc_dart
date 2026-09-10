---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/upgraded_then_silent.dart
round: 288
commit: eda32fc7
paths: [packages/transport/rpc_dart_websocket/lib/**]
status: valid
---

# P-35 — the peer that upgrades and then goes silent

P-25's question one stage later. P-25 opens raw TCP sockets and never speaks; this
completes the websocket handshake, gets its endpoint, and then never speaks
websocket — so it answers no PING, which is what a NAT box or a mobile network
that stopped forwarding looks like server-side.

The peer is a RAW socket that writes the upgrade request by hand and never reads
the response. A real `WebSocketChannel` client would answer pings automatically,
which is the one thing this must not do.

## Measures

Endpoints held, contracts constructed, contracts DISPOSED — the third is the one
that matters, because an endpoint holds the application's contracts and an
undisposed contract keeps whatever it owns for the life of the process.

## Control

`arm=on`, one constructor argument different.

```
arm  pingInterval  endpoints held  contracts built  contracts disposed
off  null                      20               20                   0
on   300ms                      0               20                  20
```

`HttpServer.idleTimeout` is printed in both arms and reads 2 minutes in both,
reclaiming nothing — it governs idle HTTP connections between requests, and an
upgraded socket has left that management.

> **This bench exists because a round quoted the function's own doc comment
> instead of running anything.** The doc carried a table from a TCP-relay
> experiment; the conclusion survived re-measurement, but the round had no right
> to it until these numbers existed. A number you did not produce is not a
> measurement.
