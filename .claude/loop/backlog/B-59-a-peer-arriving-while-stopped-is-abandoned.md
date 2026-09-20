---
status: decided by owner (round 415)
round: 401
commit: 762fa760
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/restart_the_way_the_error_says.dart — baseline pinned in test/restart_needs_a_new_stream_test.dart
reason: decided — a refusing state, distinct from both serving and cancelled; the subscription survives `stop()` and is released only at final teardown
---

# B-59 — a peer arriving while the server is stopped is accepted and abandoned

`RpcWebSocketServer.stop()` cancels its subscription to `connections`. The
`HttpServer` underneath is not the server's to close, so it keeps accepting, and
`rpcWebSocketConnections` keeps upgrading. On the broadcast stream the class's
own error message recommends for restartability, an event with no listener is
simply DROPPED.

So a peer that arrives in the gap completes the WebSocket handshake, believes it
has a connection, and holds a socket nobody owns:

```
handshake in the gap   accepted
closed 3 s later       NOTHING
an RPC over it         HUNG
after restart          served
```

No error, no close frame, no `grpc-status`. The peer waits until its own
deadline, if it set one — `connectTimeout` does not help, because the CONNECT
succeeded.

Reachable by an ordinary rolling restart: `stop(drainTimeout: ...)` then
`start()`. Every client that reconnects during the gap lands here.

## Why it is filed rather than fixed

The fix has to decide what a STOPPED server owes a peer it will not serve, and
every shape of it is a trade:

```
shape                                   cost
keep consuming after stop, close what   "stopped" no longer means "not
  arrives                               listening", and holding the
                                        subscription is exactly what makes a
                                        single-subscription stream unrestartable
close the HttpServer in stop()          the server does not own it; the whole
                                        design is that it consumes a stream
                                        somebody else built
document it only                        done in round 401's message change, and
                                        it is not a fix
```

The first is the only one that answers the peer, and it inverts the
`_connectionsSub?.cancel()` that `stop()`'s own comment says is load-bearing:
*"Stop ACCEPTING first. A connection arriving after the endpoints are closed
still gets handled, and lands in `_endpoints` AFTER the clear below — so nothing
closes it and its contracts are never disposed."* Cancelling protects against
one leak; not cancelling would answer this one. Both cannot be had without a
third state.

## Owner decision

**Taken: a refusing state, which is the third state this record says the two
halves cannot be had without.**

`stop()` does not cancel `_connectionsSub`. It switches the server into a mode
where an arriving connection is CLOSED immediately and never reaches
`_endpoints`; the subscription is released only at final teardown, so `start()`
has a live subscription to switch back.

This is the shape the table above rules out under "keep consuming after stop",
and the reason it is available is that the table conflates two things. What
makes the stream unrestartable is CANCELLING the subscription, not holding it —
and what the load-bearing comment protects against is a connection landing in
`_endpoints` after the clear. A refusing mode never lets it land there at all,
so the leak is covered by a different mechanism rather than by the cancel.

**Proposed by the agent during the backlog review, not established by a round.**
The round that carries it out has to measure it, and the claim to attack first
is the one above: that refusing covers the leak the cancel was there for. The
existing baseline is `restart_needs_a_new_stream_test.dart`, whose expectation
carries its own inversion instruction.
