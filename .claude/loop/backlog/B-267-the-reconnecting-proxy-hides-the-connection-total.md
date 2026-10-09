---
status: open
round: 736
commit: a94aca2c
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: —
reason: risk — forwarding the capability through a proxy whose inner transport changes on reconnect lets charges taken on one connection be released on the next
rank: 4
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

## Owner decision

—
