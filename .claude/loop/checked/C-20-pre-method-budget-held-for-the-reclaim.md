---
round: 215
commit: d0612f96
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
scope: [core]
---

# C-20 — the pre-method budget is held until the reclaim, on purpose

**Do not re-open this as a leak.** The `endStream` row of P-07 looks exactly
like one in isolation, which is why it is written down here.

A peer that sends a payload frame for a stream and then half-closes without ever
naming a method leaves those bytes charged against the connection's pre-method
budget. `_handleEndOfStream`'s `methodKey == null` branch sets
`endOfStreamPending` and returns instead of cleaning up, because on a reordering
transport the metadata may still be in flight behind the EOS — and covering that
reorder is the only reason the buffer exists.

    KiB held after each of six rounds, 64 KiB parked, 256 KiB ceiling:

      metadata arrives afterwards        [0, 0, 0, 0, 0, 0]
      peer half-closes, 60 s reclaim     [64,128,192,256,256,256]
      peer half-closes, 300 ms reclaim   [0, 0, 0, 0, 0, 0]
      nothing more arrives, 300 ms       [0, 0, 0, 0, 0, 0]

Both bounds work: volume caps at the ceiling and refuses beyond it, time caps at
`halfOpenStreamTimeout`.

## Control

Two. The `metadata` mode, so the bench is not merely watching bytes get parked;
and an ABLATION making `_releasePreMethodBytes` a no-op, under which all four
modes climb and stick — including the ones that are clean in the real code. That
is what separates "held by the timeout" from "never released".

## The exposure, and why it is not a defect

A peer can occupy its connection's whole pre-method budget for
`halfOpenStreamTimeout`, 60 s at the default, with two tiny frames per stream.
While it is full, a legitimately reordered frame on that connection is refused
with RESOURCE_EXHAUSTED — and that refusal fails only the offending stream.

A connection belongs to one client, so this is self-harm. It would matter on a
shared or proxied connection where one tenant's frames reach another's pipeline;
nothing in this repository builds that, and if something ever does, the budget
should be charged per tenant rather than per connection. That is the condition
to re-open on — not a new measurement of the same numbers.
