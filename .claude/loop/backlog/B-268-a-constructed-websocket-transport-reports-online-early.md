---
status: awaiting owner
round: 753
commit: 36a2241a
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/r753_online_before_ready.dart
reason: owner decision — the fix is a new core capability and a new awaited step on every connect
rank: 2
---

# B-268 — a transport built on an unconnected channel reports online

`RpcWebSocketCallerTransport(channel)` over a channel still connecting reads
`health() == healthy` at once, and `RpcClientConnection` emits Online as soon
as its factory returns such a transport. Round 747 fixed the crash that came
with it (web_socket_channel's unobserved `ready`).

Measured again in round 753, no server at all, `maxAttempts: 4`, P-258:

```
                            ctor (factory skips ready)   ready (control)
  Online emitted            4                            0
  call made at Online       status 14 after 23 ms        -
  factory calls             4                            4
  final state               Disconnected                 Disconnected
  uncaught errors           0                            0
```

So the cost is false Online events: each attempt flaps Online -> Offline
within ~5-25 ms, and a call made in that window fails fast with a retryable
status. Attempts honour `maxAttempts` and the backoff (round 748). No hang,
leak or crash. `RpcClientConnection`'s own dartdoc example awaits
`ch.ready`; the websocket README's constructor section does not say to.

`RpcClientConnection` cannot tell: it emits Online when the factory returns
and asks the transport nothing. A fix needs a readiness capability in core
(the transport exposes "not ready yet", the connection awaits it before
Online, bounded by `connectTimeout`) — new public API and a new wait on
every connect (L-22), for a defect whose measured cost is the table above.

Question for the owner: add the readiness capability, document "await
`channel.ready` before handing the channel to an `RpcClientConnection`
factory" in the websocket README only, or leave it?

Round 746 found it, 747 fixed the crash, 753 measured the rest.

## Owner decision

—
