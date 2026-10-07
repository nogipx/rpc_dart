---
status: closed (round 700)
round: 700
commit: feaf34de
paths: [packages/core/rpc_dart/lib/src/endpoint/middleware.dart, packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart, packages/core/rpc_dart/lib/src/endpoint/peer_endpoint.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/peer_middleware_direction.dart
reason: "owner decision — a new public field: middleware and interceptors on a peer run for both directions and nothing in their context says which. A capability, not a failure; kept in the loop at the owner's request rather than moved to the roadmap (B-01's precedent)"
---

# B-245 — middleware on a peer cannot tell an outgoing call from an incoming one

## Seen (owner review after round 659)

`RpcPeerEndpoint` mixes in both pipelines over one `RpcEndpointBase`, so its
one `_middlewares` list and one `_interceptors` list run for calls it makes
(`caller_pipeline.dart:448`) and calls it serves (`responder_pipeline.dart:1471`).
`RpcMiddlewareContext` carries `endpoint`, `serviceName`, `methodName`,
`context` -- identical in both directions.

```
peer A, one middleware; A calls B, then B calls A
A middleware invocations: 4
request out  endpoint=A service=S method=echo hasCallScope=false headers=[grpc-accept-encoding, x-route-service]
request in   endpoint=A service=S method=echo hasCallScope=true  headers=[grpc-accept-encoding, x-request-id, x-route-service, x-trace-id]
```

The only differences are incidental: `RpcCallScope` is attached on the
responder path only, and the responder's context carries the inbound id
headers. Neither is a contract, and middleware keying on them breaks the day
either moves.

## Severity

Nothing is lost on a caller or responder endpoint, where the direction is the
endpoint's. On a peer, middleware that should act on one side only -- auth
injection on outgoing, auth checking on incoming, per-direction metrics --
runs on both, or relies on the incidental signals above. Low: a missing
capability, not a wrong result.

## Options

1. **A direction field on `RpcMiddlewareContext`**, set by the caller and
   responder pipelines. Additive, `feat` -- provided it is optional in the
   public constructor (or defaulted); required, it breaks anyone constructing
   the context directly, e.g. in middleware tests. Interceptors get it for
   free, they receive the same context.
2. **Leave it, documented:** on a peer, middleware runs in both directions and
   cannot tell which.

The owner listed option 1 only; option 2 is the branch that keeps the API.

## Outcome (round 700)

FIXED as decided: `RpcMiddlewareContext.direction` (`RpcCallDirection.outgoing` /
`.incoming`), set by both pipelines, optional for hand-built contexts.
`../rounds/700-peer-middleware-knows-the-direction.md`.

## Owner decision

2026-10-07: **option 1**, a direction field on `RpcMiddlewareContext`.
