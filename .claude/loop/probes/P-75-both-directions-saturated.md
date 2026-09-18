---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/bidi_both_directions_saturated.dart
round: 384
commit: 69d24a76
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-75 — both directions of one bidi call past the window at once

## Why it exists

P-64 called the two directions independent on 30 tiny messages over a pair — a
size at which the flow-control window never engages. The only configuration in
which one direction can hold the other is both of them past the window at the
same time, and nothing had run it.

## Measures

Four counts, all driven by demand rather than buffered: `produced` (what the
library pulled from the caller's generator), `handlerGot`, `handlerSent`,
`callerGot`. Window 64 KiB, messages 32 KiB, so two messages fill it; 400
offered each way; 3 s per arm.

Arms: `reading` (the caller consumes while sending), `paused` (its response
subscription is PAUSED, then RESUMED), and two single-direction controls —
`requestOnly` against a handler that answers nothing, `responseOnly` against one
that pushes unasked.

Both links, the second through the same 25 ms-each-way Dart relay as P-74.

## Control

The two single-direction arms are what make the `paused` reading meaningful: if
one direction stalled because the library couples them, the direction with
nothing opposite it would stall too. Neither does — each runs flat out.

The resume is the second control, on the same arm: back-pressure recovers,
a deadlock does not.

## The numbers (round 384)

```
arm            direct link                          +50 ms round trip
reading        400 / 400 / 400 / 400                94 / 92 / 92 / 88
paused  (3s)    11 /   6 /   6 /   0                11 /   6 /   6 /   0
        resumed 400 / 400 / 400 / 400               145 / 141 / 141 / 139
requestOnly    400 produced, 400 taken              144 produced, 143 taken
responseOnly   400 pushed,   400 received           142 pushed,   137 received
```

`paused` stalls at ~6 because the MIRROR handler cannot take the next request
until its previous response has gone out — the application's coupling, which
the two controls isolate from the library's.

## What it establishes, and what it does not

Establishes: the two directions are independent under saturation, a blocked
response direction throttles rather than deadlocks, and it recovers completely.

Does not cover a handler that is itself concurrent (this one is a mirror), a
window smaller than one message, or a link that loses packets. The arms share a
process, so a still-running handler from a previous arm can touch the shared
counters — read each arm's shape, not a single cell.
