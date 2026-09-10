---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/rapid_reset_cpu.dart
round: 283
commit: d324df2a
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-32 — what a flood costs an UNRELATED client

C-32's other half. The observable is deliberately not CPU: it is a second
connection making ordinary calls throughout the attack and reporting their
latency, which is what a starvation attack actually costs an operator. RPC-18's
evidence used the same shape.

Three arms — `idle` (no attacker), `reset` (streams opened and terminated at
once) and `normal` (the same streams, not reset).

## Measures

Median and WORST victim latency in microseconds. The median answers "is the
server slower"; the worst answers "did anyone stall", and here only the second
moves — a burst monopolises the loop without shifting the average.

## Control

Two, and the `normal` arm is the one that decides the verdict: it separates
"2000 streams is a lot of work" from "resets are cheap for the attacker".

```
arm      attack streams  victim median  victim worst
idle                  0        1241 us       2367 us
reset              2000        1046 us     373458 us
normal             2000         648 us     679531 us
```

> **The control came back WORSE than the case under test, and that is the
> answer.** 679 ms against 373 ms means the stall belongs to 2000 concurrent
> streams of admitted work, not to the reset — resetting REDUCES the cost,
> because the cancel lands before dispatch (round 277). A bench whose control
> moves further than its subject has refuted the hypothesis, not failed.

**Carry RPC-18's caveat when reusing this.** An in-process flood yields the
event loop between writes, so absolute starvation is muted against a
cross-process attacker. What stays valid is the COMPARISON between arms, since
all three run in the same harness — which is why the verdict rests on
`normal > reset` and not on either number alone.
