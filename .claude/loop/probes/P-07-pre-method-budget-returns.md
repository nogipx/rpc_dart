---
file: packages/core/rpc_dart/.dart_tool/probe/pre_method_budget_returns.dart
round: 215 — the validating round
commit: d0612f96
paths: [packages/core/rpc_dart/lib/src/endpoint/**]
status: valid
---

# P-07 — does the pre-method byte budget come back?

Driven at the RAW transport, because the thing under test is a frame ordering no
endpoint API will produce on purpose: a payload frame for a stream whose method
is not yet known. Six iterations of "park a quarter of the ceiling on a fresh
stream, then end that stream", reading `preMethodBufferedBytes` from the
responder's own metrics after each.

Run it with `melos exec --scope=rpc_dart -- fvm dart run
.dart_tool/probe/pre_method_budget_returns.dart`. The knob is the teardown mode;
`halfOpenStreamTimeout` is deliberately LONG except in the two modes that are
about the reclaim, because the budget's comment says the timeout used to be the
only thing bounding this and a short one everywhere would hide a leak.

## Measures

`preMethodBufferedBytes` — the connection-wide `_respPreMethodBytes` counter,
already public in `collectEndpointMetrics`. A direct counter, not an inference
from behaviour.

## Control

Two, and the second is what makes this a bench:

1. **`metadata`** — the headers arrive after the payload, the legitimate reorder
   the buffer exists for. It must return to zero, or the bench is measuring
   parking rather than release.
2. **The ablation** — `_releasePreMethodBytes` made a no-op.

```
                     released      ablated
  metadata      [0,0,0,0,0,0]   [64,128,192,256,256,256]
  endStream     [64,128,192,     [64,128,192,256,256,256]
                 256,256,256]
  endStreamShort[0,0,0,0,0,0]   [64,128,192,256,256,256]
  reclaim       [0,0,0,0,0,0]   [64,128,192,256,256,256]
```

KiB held, ceiling 256 KiB, parking 64 KiB per round. Under the ablation every
mode climbs and sticks, so the bench sees a release failure at full strength.

**Read the `endStream` row with `endStreamShort` beside it.** Alone it looks
like a leak; the two together say it is the deliberate reorder deferral, holding
until `halfOpenStreamTimeout` (60 s at the default, 300 ms in the short mode).
That pair is the whole point of the bench.
