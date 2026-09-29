---
status: closed (round 512)
round: 512
commit: e30dc4f7
paths: [packages/core/rpc_dart/lib/src/logger/log_scope.dart, packages/core/rpc_dart/lib/src/logger/log_controller.dart]
probe: P-150
reason: "closed on the isInternal half — CONFIRMED at 235.5 ns against a bool read's 1.8 ns with 20 overrides, now 12.6 ns and flat. The child()/withContext() allocation half is untouched and unmeasured"
---

# B-121 — `isInternal` is a linear scan over scope overrides, not a bool read

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`LogScope.isInternal` → `_controller.accepts` → `_resolveLevel`, which walks `_scopeLevels` with `startsWith` on every call; the guards run dozens of times per message, and CLAUDE.md describes them as a bool read.

## The shape

`packages/core/rpc_dart/lib/src/logger/log_scope.dart:73-79`, `log_controller.dart:81-84, 226-240`.
`child()`/`withContext()` also allocate a new scope and concatenate names per
call (`UnaryCaller`, `StreamProcessor`, `CallProcessor`, `_cacheContext`).

## Why it matters

Cost proportional to the number of configured scope overrides, paid on every
guarded call site.

## Witness a round would build

Guard calls/s with 0 and 20 scope overrides.

## Fix sketch

Cache the resolved level per (scope, tag) and invalidate on configuration change.

## Outcome (round 512)

**CONFIRMED and fixed on the `isInternal` half.**

```
                                      before      after
0 scope overrides                     21.8 ns     18.7 / 21.1 ns
20 scope overrides                   235.5 ns     12.9 / 12.6 ns
CONTROL LogScope.noop (a real bool)    1.8 ns      1.8 /  1.9 ns
```

18x at twenty overrides, and **flat** — the cost no longer depends on how many
overrides the application configured.

Fixed as the sketch says, with three decisions worth recording:

- **Keyed by scope alone.** A tag override is an O(1) read taken BEFORE the cache, so
  on a miss the answer depends on the scope only — one map, and tag changes need no
  invalidation.
- **`minLevel` drove the design.** It is a public mutable field with no setter to
  hook, so the cache remembers which level it was built under and discards itself
  when that differs. One comparison per lookup instead of a correctness bug, and no
  API change.
- **Bounded at 512 and cleared wholesale**, because `child()` concatenates names.

**The guard is still 7x a bool read** (12.6 vs 1.8 ns), so `CLAUDE.md`'s description
of it is still not literally true. Closing that needs the cache on the `LogScope`
rather than the controller, with an invalidation path to every scope issued — much
more machinery for ~11 ns.

**Most deployments never paid this**: the idiom is `_log = logger ?? LogScope.noop`,
and the noop's `isInternal` is a literal `false`. What this fixes is the instrumented
build with overrides configured, which is the case the guard exists for.

## Still open, not measured

`child()` and `withContext()` allocate a new scope and concatenate names per call, at
`UnaryCaller`, `StreamProcessor`, `CallProcessor` and `_cacheContext`. Nothing was
varied on that half; it wants its own bench and would be its own round.

## Owner decision

—
