---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/a_tcp_syn_builds_an_endpoint.dart
round: 274
commit: 508fba09
paths: [packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**]
status: valid
---

# P-25 — what a connection that never speaks costs a server

Opens N sockets and sends NOTHING — not even the 24-byte h2 connection preface —
then reads the server's own counters: `endpoints`, contracts CONSTRUCTED and
contracts DISPOSED. Repoint it at any "how much does the server do before the
peer proves anything?" question by changing what the socket sends.

The sibling half runs the identical shape against the websocket server:
`packages/transport/rpc_dart_websocket/.dart_tool/probe/a_tcp_syn_against_the_sibling.dart`

## Measures

`server.endpoints.length` and a construction counter in the contract's own
constructor. **Not RSS**: it moved by -28.7, -17.5 and +0.4 MiB across three runs
of the same 200 connections, so it says nothing here. The library's counters do.

## Control

Two, and they answer different halves.

`arm=ping` turns on the one reclaim this server has, changing a single
constructor argument. `arm=preface` sends the h2 preface, separating "accepted a
socket" from "spoke HTTP/2". The websocket sibling is the third: same attack,
different server, and the number that says whether 200 is normal.

```
server / arm         endpoints  contracts built  contracts disposed
http2  default          200          200                 1
http2  ping               0          200                 -
websocket                  0            0                 -
```

> **Poll for the release, do not sleep for it.** A first run slept 2s after
> destroying the peers, read `endpoints 200` and nearly reported a leak. Polling
> to a 15s deadline gives `endpoints 0, contracts disposed 201` — the teardown is
> slow, not missing. The claim "nothing releases it" is only worth making
> against a deadline.
