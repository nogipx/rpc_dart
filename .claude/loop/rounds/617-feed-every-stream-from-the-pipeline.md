---
round: 617
verdict: FIXED
packages: [rpc_dart]
lens: RPC-20
bench: P-219 — reused
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S1
---

# Round 617 — feed every stream from the pipeline

## Target

B-226, by the owner's choice of direction (2026-10-02). Server-stream and bidi
read their requests from the transport's per-stream view, which gets a frame
only if it exists when the frame is dispatched. Any async hop between the
transport and the pipeline loses requests.

## Hypothesis

A decorator that does asynchronous work per inbound frame loses a peer's bidi
requests on a plain channel transport, not only through the websocket wrapper
that round 615 fixed.

## Before

`a_decorated_transport_loses_no_request_test.dart`: a server peer calls a client
peer whose transport is wrapped in a decorator delaying `incomingMessages` by a
timer.

```
decorated    bidi TIMEOUT       server-stream 'watched it'
control      bidi 'echo hi'     server-stream 'watched it'
```

A bare `asyncMap((m) => m)` was NOT enough on the in-memory pair: its frames
arrive several turns apart, unlike a socket read. The timer is what a decorator
doing real per-frame work (an auth lookup, a log write) costs.

## Control

The same two calls on the undecorated transport.

## Mechanism

The same as round 615, without the wrapper. The pipeline binds the call's
per-stream view on the opening frame, the transport routes each later frame
there only if the view already exists, and broadcast copies are ignored once
the call is bound.

## After

```
decorated    bidi 'echo hi'     server-stream 'watched it'
```

Server-stream and bidi, codec and zero-copy alike, are fed by
`_pipelineFedRequestStream`, the path client-stream has used since round 594.
The pipeline forwards every frame it sees itself, defers the stream's flow
credit, and returns it as the handler consumes. A half-close for any stream
with a sink is handed to it in `_handleEndOfStream`, ahead of the shape
dispatch. Their request bytes are now charged to the pipeline budget, which
since round 609 shares the transport's connection total. The bidi arm of
`the_connection_total_is_bounded_test.dart` holds under the new path.

## Canary

`_pipelineFedPreBound` switched back to `_stateBoundStream`: `a peer call
through an async decorator gets its requests` fails with
`['TIMEOUT', 'watched it']`.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (rpc_dart +1924,
websocket +271, http2 +275, isolate +93), `melos run format:check`,
`melos run license:check`, `melos run test:web` — green.

## Not fixed

Zero-copy unary still binds through `_stateBoundStream`. Its frames are direct
objects on an in-memory transport, where no decorator sits between the halves in
this repository. Server-stream passed even through the decorator before the fix,
because its one request and the half-close are handled by the paths that do not
read the view. It moved anyway, so no shape depends on the order.

## Links

Lead `../backlog/B-226-the-bind-relies-on-microtask-order.md` — closed.
Bench `../probes/P-219-the-streaming-shapes-across-a-reconnect.md` — reused.
Lens `../lenses/RPC-20-the-window-before-the-first-listener.md` — `applied: [..., 617]`.
Test `packages/core/rpc_dart/test/endpoint/a_decorated_transport_loses_no_request_test.dart`.
