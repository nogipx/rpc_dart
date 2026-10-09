---
file: packages/core/rpc_dart/.dart_tool/probe/b121_guard_cost.dart
round: 512
commit: e30dc4f7
paths: [packages/core/rpc_dart/lib/src/logger/log_controller.dart, packages/core/rpc_dart/lib/src/logger/log_scope.dart]
status: valid
---

# P-150 — what does `if (_log.isInternal)` cost?

## Why it exists

`CLAUDE.md` prescribes that guard around every interpolating `internal`/`trace`/
`debug` call and describes it as "a bool read". The repo has hundreds of such sites,
so if it is not a bool read the cost is paid everywhere, whether or not logging is
on. The lead asks for guard calls/s at 0 and 20 overrides; that is exactly the right
shape, because the scan the guard runs is proportional to the override count.

## The harness

A `LogController` at `warning` and a `LogScope` named like a real one
(`rpc_dart.transport.websocket.caller`), with the guard in a tight loop after a
20 000-iteration warm-up. Two million iterations per arm, reported in nanoseconds
because the quantity is small enough that microseconds would round it away.

The 20 overrides are deliberately **non-matching** (`some.other.subsystem.$i`): that
is the worst case for a longest-prefix scan, since every entry must be tested and
none short-circuits — and it is also the ordinary case, because an application tunes
the subsystems it cares about and this scope is not one of them.

## The numbers (round 512)

```
                                      before      after
0 scope overrides                     21.8 ns     18.7 / 21.1 ns
20 scope overrides                   235.5 ns     12.9 / 12.6 ns
CONTROL LogScope.noop (a real bool)    1.8 ns      1.8 / 1.9 ns
```

18x at 20 overrides, and the cost no longer grows with the override count — the
after-figures at 0 and 20 differ only by noise and ordering.

## Measures

Nanoseconds per guard evaluation. Not logging throughput: the guard's whole purpose
is to run when logging is OFF, so what matters is what it costs to decide not to log.

## Control

**`LogScope.noop`, whose `isInternal` is a literal `false`.** That is what a real bool
read costs on this machine — 1.8 ns — and without it "235 ns" has no scale. It also
sets the floor the fix could aim at: 12.6 ns is still 7x a bool read, so the map
lookup plus the tag check plus the `minLevel` comparison are not free either, and the
record should not claim the guard is now what CLAUDE.md describes.

`LogScope.noop` is also the honest reminder that most deployments never pay this at
all: the library's idiom is `_log = logger ?? LogScope.noop`, so an application that
configures no logger gets the 1.8 ns path everywhere.

## What it establishes, and what it does not

Establishes: `isInternal` was a scan whose cost grew with configured overrides —
235 ns at twenty, 128x a bool read — and caching the resolution per scope makes it
12.6 ns and flat.

Does NOT establish that this is visible in any application. It is 235 ns at a site
that runs perhaps tens of times per call, against calls measured elsewhere in this
run at 57-100 us. The case where it would matter is a deeply instrumented build with
many overrides and logging off, which is the case the guard exists for.

Does NOT cover the lead's other half: `child()` and `withContext()` allocating a new
scope and concatenating names per call. Nothing here was varied on that.

## Reading

rpc_dart — **its control is `LogScope.noop`, whose `isInternal` is a literal
`false`**, which is what a real bool read costs on this machine; without it
"235 ns" has no scale, and with it the round could say honestly that its own
fix reaches 7x a bool read rather than 1x. The 20 overrides are deliberately
NON-matching, which is both the worst case for a longest-prefix scan and the
ordinary one. Reported in nanoseconds because microseconds would round the
quantity away. The noop arm is also the honest reminder that most deployments
never pay this at all.
