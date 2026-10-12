---
round: 838
verdict: FIXED
packages: [rpc_dart_websocket, rpc_dart]
lens: RPC-17
bench: P-277 — reused
commit: yes
severity: S1 — "memory or CPU a peer or ordinary use can grow without bound"
release: changelog
---

# Round 838 — the websocket upgrade gets the header bound

## Target

B-287, decided by the owner 2026-10-11 in this round: a copy of round 811's
socket watcher in rpc_dart_websocket, and a helper that binds the socket for
`rpcWebSocketConnections`, instead of moving the watcher to a shared package
or depending on rpc_dart_http.

## Hypothesis

Bound by a socket rpc_dart owns, an unfinished upgrade header block is cut by
bytes and by time, as on `RpcHttpServer`; on a plain `HttpServer.bind` it is
held for as long as the client keeps the connection.

## Before

P-277 (`header_hold_attacker.py`, 300 connections, 900 KiB each, held 12 s),
server `.dart_tool/probe/r838_server.dart plain`:

```
  plain HttpServer.bind   0 of 300 closed, server RSS +269 MiB (peak 325)
```

## Mechanism

dart:io parses a request header block below every rpc_dart limit and keeps
it until the block ends or the connection does; `rpcWebSocketConnections`
only sees requests whose block ended, and it is handed an `HttpServer` it
did not bind.

## Fix

- `bindRpcWebSocketHttpServer(address, port, {policy, maxHeaderBytes,
  headerTimeout = 60 s, maxConnections, backlog, v6Only, shared})` in
  `io.dart`: binds a `ServerSocket`, wraps it so each connection's FIRST
  header block is cut past `maxHeaderBytes` (default 4x the policy's head,
  round 811's formula) or `headerTimeout` from the accept, refuses
  connections past `maxConnections` (off by default), and returns an
  `HttpServer` whose `close` also releases the socket (`HttpServer.listenOn`
  leaves a socket it was given open).
- `rpcWebSocketConnections` closes a connection it refuses
  (`persistentConnection = false`), so a connection carries one header block
  and the first one is the only one to bound.
- The README's server example binds with the helper, and its proxy section
  has the option table. The shipped skill's security reference names both
  servers' bounds.

## After

```
  bounded, 900 KiB each   the first connection cut at the byte bound (the
                          attacker's own send fails, BrokenPipe)
  bounded, 0 KiB each     300 of 300 closed at headerTimeout 8 s, RSS +1 MiB
```

Witness `rpc_dart_websocket/test/an_unfinished_header_block_is_bounded_test.dart`:
a block over 16 KiB cut; a block that never ends cut at a 300 ms timeout
(GUARD: held without it); a connection past `maxConnections: 1` refused;
GUARDs: an honest client served, also 2.5 s past the deadline, and closing
the server releases the port.

## Canary

All four mechanisms switched off together in place (each witness names its
own): the byte witness, the timeout witness and the connection witness fail
`Expected: 'closed' Actual: 'open'`; the port GUARD fails `SocketException:
Failed to create server socket ... shared flag`. Restored.

## The verdict questions

1. Only how the HttpServer is bound differs.
2. Yes: 0 of 300 closed and +269 MiB against all closed and +1 MiB.
3. In the server's own process, and at the attacker (closed or not).
4. 300 connections over 12 s, read at the end.
5. Quoted.
6. Four mechanisms, four witnesses, one canary run.
7. S1 by "memory ... a peer ... can grow without bound": the block is held
   per connection with no time bound and the connection count has none.
8. none.
9. none.
10. Siblings below.
A1. Defaults. A2. Volume and time. L1. The byte witness sends 64 KiB under
    dart:io's own 1 MiB cap, so the cut is ours.

## Gate

`melos run analyze`, `test:unit`, `check:skills` green;
`websocket_web_smoke_test` on node (io.dart stays out of the web library).

## Siblings

- scope: transport.http-like — only an HTTP server has a request header block before the transport begins
- websocket: fixed here
- http: clean — measured, round 811's `an_unfinished_header_block_is_bounded_test` (P-297)
- http2: read — `http2_header_block_guard` bounds header blocks on that transport (round 145); not run here

## Not fixed

- The bound is opt-in: an application that binds its own `HttpServer` keeps
  the old exposure. The README example now uses the helper.

CHANGELOG line (minor): "rpc_dart_websocket: `bindRpcWebSocketHttpServer`
binds an `HttpServer` for `rpcWebSocketConnections` that bounds each upgrade
request's header block by bytes and time and, optionally, the number of
connections. A refused upgrade now closes its connection."

## Links

Lens `../lenses/RPC-17-limit-fires-after-residency.md`. Bench
`../probes/P-277-held-request-header-blocks.md`. Lead
`../backlog/B-287-the-websocket-servers-header-block-is-the-applications.md`
(closed). Round `811-an-unfinished-header-block-is-bounded.md`.
