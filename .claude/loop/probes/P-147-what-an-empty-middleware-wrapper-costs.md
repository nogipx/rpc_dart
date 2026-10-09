---
file: packages/core/rpc_dart/.dart_tool/probe/b117_broadcast_per_message.dart
round: 509
commit: 7b3bae0e
paths: [packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart]
status: valid
---

# P-147 — what does an empty middleware wrapper cost?

## Why it exists

Reused rather than written: round 508's server-stream bench measures exactly the
quantity this lead is about — microseconds per message on a stream of tiny messages
— so the round that followed it had no reason to build a second one. **Registering
it under a new number is what keeps that reuse visible**; the file is shared with
P-146 and both records say so.

## The harness

Server stream of 10 000 one-character messages over the in-memory pair, five timed
runs per process, no middleware configured. Unchanged from P-146.

## The numbers (round 509)

Run-set minima, which is the statistic this round leans on:

```
always wrapped      5.647 / 5.582 / 5.456            us/message
bypassed if empty   4.438 / 4.564 / 4.419 / 4.520    us/message
```

About 1.03 us per message, roughly 19%.

## Measures

Microseconds per message. **Reported as the MINIMUM across run sets, not the
median**, and the reason is specific rather than stylistic: noise on this machine
only ever adds time — GC, scheduling, other suites — so the floor is the closest
thing to the quantity being measured, and it is the statistic that survives a noisy
afternoon.

The medians say why that mattered here. The ablated sets were tight (5.456 to 6.259
across three sets), but the fixed sets were not: one read `min 4.419 median 4.441
max 4.786` and another `min 4.564 median 5.949 max 6.247`. Comparing medians across
those two would have given anything between 19% and nothing at all. **The minima
never overlap** — every ablated set floors above 5.45, every fixed set below 4.57 —
and that separation is the result.

## Control

Round 508's own controls carry over: per-message cost is not flat across message
counts (75.8 / 17.9 / 7.07 us at 100 / 1000 / 10 000), so only the largest arm
measures a per-message cost at all, and the smaller arms would be reporting call
setup.

What this round adds is the discipline of **seven run sets rather than two**. The
first comparison attempted — one set each — read `4.710` against `5.763` medians and
looked conclusive; the second fixed set's median of `5.949` would have reversed it.
Two sets are not a measurement when the spread is this wide.

## What it establishes, and what it does not

Establishes: wrapping a stream in `async*` to forward each message unchanged costs
about 1.03 us per message, and skipping the wrapper when `_middlewares` is empty
recovers it.

Does NOT establish anything about the other layers the lead names — `handleServerStream`,
`_withHandlerSlotStream`, `StreamBridge`, `_bridgeCallerResponses`, the bidi
controller and `.transform`, or the `StreamProcessor`/`CallProcessor` controllers
that only a no-op listener reads. Only the two middleware helpers were varied, and
the ~4.4 us per message that remains is where those layers live.

Nor does it say the 19% is visible to a user: at 4.4 us per message this path
sustains well over 200 000 messages/s on one isolate, which no real transport feeds.

## Reading

rpc_dart — **the same FILE as P-146, registered under its own number**,
because round 508's bench already measured this exact quantity and rebuilding
it would have been the waste. Reports run-set MINIMA rather than medians, and
says why: noise here only ever adds time, so the floor is closest to the
quantity. That mattered — two run sets read `4.710` against `5.763` and looked
conclusive, and the next set's median of `5.949` would have reversed it; seven
sets later the minima never overlap.
