---
file: packages/core/rpc_dart/.dart_tool/probe/b106_zero_copy_backpressure.dart
round: 497
commit: 60e4d3f8
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/core/transport.dart]
status: valid
---

# P-135 — does the flow-control window reach a direct object?

## Why it exists

`bufferedBytes` is 0 for a `directPayload`, so the question is whether the
per-stream window can bound a zero-copy producer at all. A run that merely shows
"the producer got far ahead" cannot answer it — the library does not throttle
producers by decision (`checked/C-19`), so getting ahead is expected on both
paths.

**What discriminates is VARYING THE WINDOW.** If the window is the thing that
bounds, shrinking it must move the number; if direct objects are unmetered, it
cannot.

## The harness

A server-stream handler minting a fresh 1 KiB object per message in a tight loop,
a consumer that pauses after the first message, and a counter incremented inside
the handler. One second of settle. Two modes (zero-copy over `memoryPair`, codec
over `pair`), two consumer behaviours, then both modes again with the window made
tiny.

The payload is MINTED per message on purpose: "a directPayload weighs nothing,
queuing it costs a pointer" holds only for an object the process already retains.

## The numbers (round 497)

```
mode      consumer   window       produced   received
zeroCopy  PAUSED     4096 KiB      247722          1
zeroCopy  draining   4096 KiB      211212     211212
codec     PAUSED     4096 KiB      189274          1
codec     draining   4096 KiB      152568     152568

the window made tiny, paused consumer
zeroCopy  PAUSED       64 KiB      274289          1
codec     PAUSED       64 KiB        5960          1
```

## Measures

Messages the HANDLER produced, counted inside the handler — the only place that
knows what the application actually generated. Received is counted in the
consumer.

RSS was the first instrument and was abandoned: it gave negative deltas across
arms (GC), which is the trap `methods/measurement.md` item 7 names. A direct
counter answers the question and does not need three scales to be readable.

## Control

Three, and the round needed all of them:

- **draining**, where no backpressure is called for. Produced is the same order
  as PAUSED, which is what says the library does not throttle producers at all —
  so "the producer ran away" is not evidence of anything by itself.
- **the codec path**, which the lead names as its control.
- **THE WINDOW ITSELF, varied.** At 64 KiB the codec path falls from 189274 to
  5960, a 32x reduction, while zero-copy goes from 247722 to 274289 — no effect.
  This is the only arm that separates "unmetered" from "metered with a generous
  bound", and without it the first four rows read as "both paths are equally
  unbounded", which is the opposite conclusion.

## What it establishes, and what it does not

Establishes: the per-stream flow-control window does not reach a direct object.
Shrinking it 64-fold changes nothing on the zero-copy path and changes the codec
path by 32x.

Does NOT establish that the codec path is adequately bounded. 5960 messages of
1 KiB is 5.8 MiB against a 64 KiB window, and at the DEFAULT window 189274
messages is 185 MiB against 4 MiB — both far looser than the knob suggests. That
is a second defect, measured here and filed as B-195, not this bench's subject.

Does NOT cover the isolate transport, which declares `supportsZeroCopy` and deep-
copies through `SendPort`; the lead's second question is untouched.
