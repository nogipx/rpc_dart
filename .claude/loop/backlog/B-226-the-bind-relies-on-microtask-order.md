---
status: open
round: 615
commit: d572e08d
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: P-219
reason: "bench — round 615 fixed the one in-repo wrapper that broke it; the invariant itself is a microtask ordering, and any IRpcTransport decorator that re-broadcasts asynchronously loses a peer's bidi requests the same way"
---

# B-226 — a peer call's bind relies on microtask order

## What round 615 found

For a stream the PEER opened, `RpcChannelTransport` broadcasts every frame and
also routes it to the stream's per-stream controller if that controller exists
when the frame is dispatched. The responder pipeline creates the controller when
it binds the call on the opening frame. After that it reads requests only from
the controller and ignores the broadcast copies.

So a request is lost whenever the transport dispatches it before the pipeline has
processed the opening frame. Directly on the transport that cannot happen,
because the broadcast delivery is scheduled ahead of the next dispatch. One
extra async hop between the transport and the pipeline breaks it.
`RpcWebSocketCallerTransport` had exactly that hop, and it lost every peer bidi
request until round 615 made its forward synchronous.

## Why it is still open

`IRpcTransport` is a public extension point and decorators are documented
(`IRpcReconnectableTransport`'s doc names them). A decorator that wraps
`incomingMessages` in its own async controller, or `asyncMap`s it, reproduces the
defect, and nothing tells its author. Client-stream is immune: the pipeline feeds
it from the frames it sees itself (`_pipelineFedRequestStream`). That is the
shape that does not depend on the order.

## Witness a round would build

`a_peer_client_gets_every_bidi_request_test.dart`'s rig over a minimal decorator
whose `incomingMessages` is `inner.incomingMessages.asyncMap((m) => m)`, against
the undecorated transport as control.

## Fix directions, unmeasured

1. Feed bidi (and server-stream) requests from the pipeline, as client-stream
   already is. That changes where those bytes are metered: rounds 594/595 counted
   bidi in the transport ledger.
2. Have the transport keep frames for a peer stream with no controller yet, and
   hand them to the controller when it is created.
3. Document the requirement on `IRpcTransport.incomingMessages` and leave it.

## Owner decision

—
