---
status: decided by owner (round 676)
round: — (not re-measured)
commit: 81530a7b
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/core/protocol.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
probe: .dart_tool/probe/parity_matrix.dart (6.call-after-peer-dead)
reason: owner decision — likely intended, but the retry consequence has not been chosen anywhere
---

# B-252 — a call after the peer died is 9 on three transports and 14 on two

Measured outside a round, by the transport parity matrix (`probe:` above), at the `commit:` sha.

The server side is killed, then the client waits 300 ms and makes one call:

```
memory     RpcClosedException/9        "Transport is closed"
isolate    RpcClosedException/9        "Transport is closed"
websocket  RpcNoConnectionException/9  "... call reconnect() ..."
http1      RpcStatusException/14       "OS Error: ..."
http2      RpcStatusException/14       "... draining (the peer sent GOAWAY) ..."
```

A call in flight when the peer dies is 14 on all five transports. Only the NEXT
call differs.

## Why it matters

`RpcRetryInterceptor` retries 14 and does not retry 9. So the same outage is
retried over HTTP and not over websocket or isolate. That is probably right:
websocket needs an explicit `reconnect()`, and a dead isolate does not come
back. But no record says so, and `checked/C-30` covers only the closed-transport
leniency, not the code.

## Owner decision

2026-10-07, round 676's batch: **unify to 14 everywhere** for a call after the
PEER died. A call after this side's own `close()` is a different event and
stays 9.
