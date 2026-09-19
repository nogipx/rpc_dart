---
status: awaiting owner
round: 401
commit: 762fa760
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/restart_the_way_the_error_says.dart — baseline pinned in test/restart_needs_a_new_stream_test.dart
reason: behaviour decision — the fix changes what `stop()` OWNS, and the obvious shape of it (keep consuming the stream after stop, to close what arrives) is the very thing that makes a single-subscription stream unrestartable
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

Needed. Should a stopped `RpcWebSocketServer` keep reading its connections
stream in order to CLOSE what it cannot serve — accepting that "stopped" then
means "refusing" rather than "not listening", and that restartability over a
single-subscription stream is lost for good?

Round 401 changed the error message to say the gap exists, which is honest and
is not a fix.
