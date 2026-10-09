---
status: open
round: 762
commit: ad501d86
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/r762_proxy_hides_total.dart
reason: risk — a flow-control-ignoring peer only, bounded at 2x the window; the forwarding fix needs a per-charge handle the interface lacks
rank: 3
---

# B-267 — the reconnecting proxy hides the connection total

`_ReconnectingTransportProxy` declares `IRpcTransport`, `IRpcStreamReset`,
`IRpcSecurityPolicyAware`, `IRpcFlowControlled` and `IRpcStreamIdSequence`.
It does not declare `IRpcConnectionBufferTotal`, which `RpcChannelTransport`
and `RpcWebSocketResponderTransport` implement. The responder pipeline finds
the capability with `transport is IRpcConnectionBufferTotal`
(`responder_pipeline.dart:154`). Behind the proxy it is absent, so the budget
falls back to its own `connectionBytes` and the transport keeps its own
total.

Reached by a responder pipeline over `RpcClientConnection`, which is an
`RpcPeerEndpoint` on a reconnecting connection. Per the interface's own doc,
both layers then each hold up to the connection total: twice the bound the
operator configured. Read only, not measured: the bound is per connection
and needs a peer endpoint over a reconnecting proxy with both layers filled
at once.

Why not fixed: forwarding `chargeConnectionBuffer` and
`releaseConnectionBuffer` to `_inner` is a one-liner. But a release that
arrives after a reconnect would hit the NEW connection's total for bytes
charged to the old one, and drive it negative. A correct fix tracks, per
charge, which inner it went to.

Lens RPC-04, round 736.

**Round 762 measured the honest case and it does not reach the doubling.**
A victim `RpcPeerEndpoint` whose client-stream handler never reads, 1 MiB
connection window, 8 honest calls sending 64 KiB messages
(`packages/core/rpc_dart/.dart_tool/probe/r762_proxy_hides_total.dart`):

```
  direct (no proxy)   32 messages = 2048 KiB taken, every call parked
  proxy               32 messages = 2048 KiB taken, every call parked
```

Flow control stops an honest sender before both layers fill, so the proxy
changes nothing for it. What remains is a peer that ignores credit: then each
layer refuses at its own total and the sum is 2x the window, bounded. That
needs a raw-frame sender built on the library's serializer (L-10); it was not
built.

## Owner decision

—
