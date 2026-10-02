---
file: packages/core/rpc_dart/.dart_tool/probe/b208_what_the_poll_costs.dart
round: 612
commit: 73590cfb
paths: [packages/core/rpc_dart/lib/src/core/drain.dart]
status: valid (round 612)
---

# P-217 — what the drain poll costs

## Why it exists

B-208: how much later than the work does `drainUntilIdle` return, given its 25 ms
poll?

## The harness

`drainUntilIdle` with a `pending()` that reports 1 until a Stopwatch passes the
work time, then 0. Overshoot is the elapsed time minus the work time. 20 runs per
work time, median and max.

## The numbers (round 612)

```
work done after    overshoot median    max
  0 ms                 0 ms             3 ms
  1 ms                26 ms            27 ms
 10 ms                17 ms            17 ms
 30 ms                24 ms            24 ms
100 ms                 8 ms             8 ms
```

## Measures

Delay one server shutdown pays past the end of its last call.

## Control

Work time 0: the drain returns at once.
