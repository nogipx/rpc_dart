---
file: packages/core/rpc_dart/.dart_tool/probe/bidi_request_direction.dart
round: 382
commit: 6a3cb2c1
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
status: valid
---

# P-70 — the request direction

## Why it exists

Four rounds measured the RESPONSE direction. B-51, filed from the consumer,
pointed at the request one: their upload is roughly 8 MB in against 400 bytes
out, so the measured direction is the cheap one.

## Measures

How many messages the library pulled from the CALLER's producer while a handler
that read one message stalled — counted inside that producer, so it measures
demand the library created. 1 MB window, 16 KiB messages, 2000 offered, 900 ms.

## Control

Two, and the second is what made the round.

**`bidi-drain`** — the same rig with a handler that drains everything. It pulls
the producer dry (2000), so a 66 elsewhere is a bound rather than a slow
producer.

**The ablation**, removing `deferFlowCredit` from `_pipelineFedRequestStream`:

```
arm             fixed   ablated
bidi-stall         66        66      <- unchanged
client-stall       66      2000      <- the bound was here
```

It moved the arm the lead did NOT name and left the one it did. That is how the
mechanism was re-attributed: `_pipelineFedRequestStream` is the CLIENT-STREAM
path. A bidi responder binds through `_stateBoundStream` and is fed by the
transport's own per-stream metering.

**An ablation that confirms sensitivity can also correct attribution**, and
here it did. A round that saw `66` and stopped would have reported the right
number about the wrong code.

## The numbers (round 382)

```
arm             pulled of 2000      MB
bidi-stall            66           1.0
bidi-drain          2000          31.3
client-stall          66           1.0
```

## What it establishes, and what it does not

Establishes: both request paths are bounded at the window, by two different
mechanisms.

Does not cover latency (in-process pair; round 378's argument for why this
class survives an RTT applies but was not re-run), nor which part of the
transport's own metering carries the bound on the bidi arm.
