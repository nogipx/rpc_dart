---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/core/drain.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-123 — both drains poll on a timer and measure their budget on the wall clock

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_runDrain` sleeps 50 ms and `drainUntilIdle` 25 ms in a loop against `DateTime.now()`, and `activeResponderCount` is an O(n) `where` per tick; a clock step shortens or extends the budget.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart:607-641`, `core/drain.dart:73-98`,
`responder_pipeline.dart:582-584`.

## Why it matters

Shutdown latency of up to one poll interval, a wrong budget under NTP steps, and
two copies of one mechanism.

## Witness a round would build

Drain with zero in-flight calls finishing at t=1 ms: measured completion time.

## Fix sketch

A completer signalled when the last stream is cleaned up, a `Stopwatch` for the
budget, one implementation.

## Owner decision

—
