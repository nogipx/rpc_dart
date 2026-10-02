---
status: open
round: 624
commit: 89340ce5
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_websocket/README.md]
probe: P-216
reason: "decision — the frame guard's ceiling comes from rpcWebSocketConnections' own policy (default 16 MiB), not the server's; a server configured above 16 MiB refuses larger messages unless the policy is passed twice"
---

# B-227 — the connections' policy is a second copy of the server's

Found by the independent audit of 2026-10-02, reproduced in round 624.

## The shape

Round 611 gave `rpcWebSocketConnections` a `policy:` parameter so the frame
guard can size its ceiling (`effectiveMaxBufferedBytes + 9`). It defaults to
`const RpcSecurityPolicy()`, independent of the policy given to
`RpcWebSocketServer`. The README's serving example does not pass it.

## Measured

Server and client at 32 MiB, connections with no policy:

```
20 MiB request   RpcStatusException(14): WebSocket connection failed with code 1002
1 KiB request    served
```

The same with the policy also passed to the connections: `20 MiB` served.

The refusal is a destroyed socket (round 611's Not fixed), so the client reads
1002 -> UNAVAILABLE, which the default retry interceptor retries, failing the
same way each time.

## Why it matters

Before 73590cfb the same setup accepted the message: raising
`maxMessageLengthBytes` on the server was enough. It is a regression for anyone
above 16 MiB, and the failure reads as a network fault.

## Fix directions, unmeasured

1. The server tells its connections the policy: the guard reads the ceiling
   from the server at upgrade time (needs a hand-off, since the connections
   stream is built before the server).
2. Default the connections' ceiling to "unbounded unless given" and document
   that the guard is opt-in. Loses round 611's protection by default.
3. Keep both parameters, fail loudly at `start()` when the two policies
   disagree.
4. Document only.

## Owner decision

2026-10-02: direction 1 — the server hands its policy to the guard at upgrade
time; the connections' own `policy:` becomes optional.
