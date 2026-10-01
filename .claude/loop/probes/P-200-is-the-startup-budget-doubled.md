---
file: packages/transport/rpc_dart_isolate/.dart_tool/probe/b157_startup_budget.dart
round: 579
commit: 513dfc6e
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
status: valid
---

# P-200 — is the startup budget really doubled?

## Why it exists

B-157 claims "two phases each get the full `startupTimeout`, so a 30 s default is really 60 s". That is an
arithmetic claim about a duration, so the arm is a clock: a worker that never becomes ready, timed against
the budget it was given.

## The harness

`RpcIsolateTransport.spawn` with a short `startupTimeout` and an entrypoint that never lets the worker
reach `ready`. Three budgets across a 4x range, so the answer is a RATIO rather than one timing.

**The stall has to be SYNCHRONOUS**, and this is the whole subtlety of the rig. The wrapper sends `ready`
immediately after `userEntrypoint(...)` RETURNS, so an entrypoint that schedules
`Future.delayed(...).then(...)` and returns stalls nothing. A busy-wait on a `Stopwatch` blocks the
worker's event loop, which is what keeps `ready` unsent.

## The numbers (round 579)

```
first version, a stall that returned immediately
    budget  500ms -> failed after  28ms (0.06x)  Null
    budget 1000ms -> failed after   0ms (0.00x)  Null
    budget 2000ms -> failed after   0ms (0.00x)  Null

with a synchronous stall
    budget  500ms -> failed after  521ms (1.04x)  TimeoutException
    budget 1000ms -> failed after 1002ms (1.00x)  TimeoutException
    budget 2000ms -> failed after 2002ms (1.00x)  TimeoutException
```

## Measures

Wall-clock from the `spawn` call to its throw, as a multiple of the budget, with the thrown type beside it.
The type is the premise check: `Null` means spawn SUCCEEDED and the arm measured nothing.

## Control

**The three budgets are each other's control.** A single reading of "about a second" proves nothing about
proportionality; `1.04 / 1.00 / 1.00` across 500 ms to 2 s is what makes 1x a property of the code rather
than of one run.

**The first version is kept in the record as the negative control it accidentally was**: `0.00x` with
`thrown == Null` is what this measurement looks like when its subject never happens — `measurement.md`
item 8.

## What it establishes, and what it does not

Establishes that a worker stalling before `ready` costs ONE budget, not two, so the lead's arithmetic is
refuted: the two timeouts are sequential but phase 1 cannot be made slow by anything a caller controls,
because the wrapper sends its `SendPort` before any user code runs.

Does NOT establish the true worst case. `spawn + startupTimeout` is the bound by reading; a machine slow
enough to make the isolate's own creation take a measurable share of the budget was not arranged.

Does NOT touch the lead's other two claims: the extra handshake round trip, and the kill/close ordering
(which was settled by reading, since the isolate it concerns is killed before it could report).
