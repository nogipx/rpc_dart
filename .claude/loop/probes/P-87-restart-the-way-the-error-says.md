---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/restart_the_way_the_error_says.dart
round: 401
commit: 762fa760
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
status: valid
---

# P-87 — restart the server the way its own error message says to

## Why it exists

`RpcWebSocketServer.start()` refuses to restart over a single-subscription
connections stream, and its `StateError` names two remedies. RPC-21 says drive
the lifecycle twice; this takes the library at its word and drives each remedy.

`start()`'s own comment names the failure it must not become: *"A server that
reports running while accepting nothing is worse than one that failed: nothing
upstream can tell there is anything to fix."*

## Measures

Per arm: whether the first call is served, what the second `start()` does,
`isRunning` after it, and whether a call then succeeds. A separate arm measures
what a peer arriving during the STOPPED window is told.

## Control

`single` — the plain stream, which must keep throwing; and `broadcast`, the
remedy that works. Between them the arms differ only in how the stream was
built, so a difference is attributable to that and nothing else.

## The numbers (round 401)

```
arm            first     restart      isRunning   then
single         served    StateError   false       -
broadcast      served    ok           true        served
fresh server   served    StateError   false       -
```

```
a peer arriving while a restartable server is stopped
  handshake        accepted
  closed 3 s later NOTHING
  a call over it   HUNG
  after restart    served
```

## The observable that was contaminated first

The abandoned-socket flag was first read AFTER the arm's own
`ws.sink.close()` and `http.close(force: true)`, and reported `closed` — its own
teardown. Snapshotted before any teardown it reads `NOTHING`. Same trap as
P-84's first rebuild, which read counters after `terminate()`.

## What it establishes, and what it does not

Establishes: over one `HttpServer` there is no "construct a new server" route —
the obstacle is the stream, and a second `rpcWebSocketConnections(http)` fails
the same way since `HttpServer` is single-subscription and already listened to.
And the working remedy has a gap in which peers are accepted and abandoned
(B-59).

Does not measure how long the gap lasts under a real `stop(drainTimeout:)`, nor
what a browser client does with such a socket, nor whether the same window
exists on `RpcHttp2Server` — that one rebinds its own socket, so it is a
different shape and worth its own arm.
