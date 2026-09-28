---
round: 465
commit: d4c92857
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
scope: [rpc_dart, rpc_dart_websocket, rpc_dart_http2]
---

# C-53 — three id-reuse mechanisms, one correct outcome

Bench: P-115,
`packages/transport/rpc_dart_websocket/.dart_tool/probe/does_an_id_come_back_after_a_reconnect.dart`.

> **Scope**: one call left open across one reconnect, on the three CALLER-side
> machines, unary shape. It does not cover several concurrent calls, repeated
> reconnects, or an id released and re-minted within one connection.

## The claim that was checked

B-76's remaining half: *"`websocket_caller_transport.dart`,
`rpc_http2_caller_transport.dart` and `_ReconnectingTransportProxy` each solve
the SAME stream-id-reuse problem, and each solves it differently"* — a `Set` of
live ids, a never-reset counter, an id watermark.

True as a description. The question round 449 and 451 both settled the same way:
a divergence is a lead about where to look, never a finding about what happens.

## The numbers

One call left open, one reconnect, one more id minted — then the operation
B-76's own body names as the cost, a late `finishSending` from the dead call:

```
             before  after  collision  late finishSending
websocket      1       3       no      no -- different id
http2          1       3       no      no -- different id
proxy          1       3       no      no -- different id
```

Three mechanisms, one outcome, and it is the right one.

## Control

`_nextStreamId = 1` restored in http2's reconnect — the reset its own comment
says is deliberately absent — and the bench sees it immediately:

```
http2          1       1      YES      YES -- same id
```

So the arms are able to observe a collision AND its consequence; a clean row is
a fact about the code rather than about the harness.

**The control also measured something the round did not go looking for.** With
http2's counter reset, the PROXY arm — which is built on that same transport —
still read `1 / 3 / no`. Its `_idWatermark` is load-bearing: it carries the
sequence across a transport that restarts its own, which is precisely the case
its doc comment describes and which nothing had exercised.

## What this does NOT license

Merging the three. They are not three answers to one question — round 451's rule,
asked here and answered:

```
websocket   keeps its transport object, needs to REJECT ids from a dead connection
http2       keeps its transport object, needs only to not rewind a counter
the proxy   REPLACES the transport, so the sequence has to cross an object boundary
```

The third cannot use either of the first two, because the object holding the
counter is gone. Unifying them would produce one class with three flags, which is
what RPC-25's "What NOT to merge" warns against.
