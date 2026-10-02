---
round: 612
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-217 — new
budget: probes 1/5, canaries 0/5
commit: yes
release: none
---

# Round 612 — twenty-five milliseconds, once

## Target

B-208: `drainUntilIdle` still polls `pending()` every 25 ms. Unifying it with the
signalled responder drain needs a new parameter, so the owner was asked whether
it is worth one.

## Hypothesis

The poll costs a shutdown a measurable delay, worth a signal.

## Before

```
work done after    overshoot median    max
  0 ms                 0 ms             3 ms
  1 ms                26 ms            27 ms
 10 ms                17 ms            17 ms
 30 ms                24 ms            24 ms
100 ms                 8 ms             8 ms
```

20 runs per row. Probe:
`packages/core/rpc_dart/.dart_tool/probe/b208_what_the_poll_costs.dart`.

## Control

The `0 ms` row: with nothing in flight the drain returns at once. The interval
is paid only when work is still running at shutdown.

## Mechanism

At most one 25 ms interval past the moment the last call ends, once per server
shutdown. The other two items in the lead: `activeResponderCount`'s `where` is
called by `pendingResponders` (once per tick, during a drain only) and by the
metrics map. Both are off the hot path. The Stopwatch-based budget stays argued
from monotonicity, not stepped with a clock, and the code comment says so.

## After

n/a — no change. Owner decision 2026-10-02: close as an accepted cost.

## Canary

n/a — no fix.

## Gate

Not run: `lib/` and `test/` byte-identical to the previous commit.

## Not fixed

Nothing in B-208.

## Links

Lead `../backlog/B-208-the-generic-drain-still-polls.md` — closed.
Bench `../probes/P-217-what-the-drain-poll-costs.md` — new.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 612]`.
