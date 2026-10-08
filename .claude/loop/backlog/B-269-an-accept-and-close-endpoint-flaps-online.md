---
status: open
round: 746
commit: 8d6a35a2
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/r746_drop.dart
reason: unmeasured — the shape is seen; its cost against a real endpoint is not
---

# B-269 — an endpoint that accepts TCP and closes it flaps the connection online

`RpcHttp2CallerTransport.connect()` returns once the TCP socket is open,
before the server's SETTINGS. Round 746 saw RpcClientConnection report
`Online` and then `Offline` several times while no server was running:

```
  state -> RpcClientOffline
  state -> RpcClientOnline
  state -> RpcClientOffline
  state -> RpcClientOnline
```

In that run the cause was a loopback self-connect to a closed ephemeral port,
a test artefact. The same shape follows from any endpoint that accepts and
closes at once, such as a load balancer with no healthy backend. To measure:
whether each such Online resets the backoff (a reconnect at the base delay
forever), and whether connect() should wait for the peer's SETTINGS.

**Round 748 answered the first: it did**, and not only for http2:
`RpcWebSocketServer` at capacity drew 28 connections in 6 s with
`maxAttempts: 4`. Fixed in `3fc2fa74`: a connection that drops within 5 s is
a failed attempt. **What remains** is the second question: Online before
SETTINGS, now bounded by the backoff.

## Owner decision

—
