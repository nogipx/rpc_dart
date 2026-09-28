---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/logger/log_scope.dart, packages/core/rpc_dart/lib/src/logger/log_controller.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
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

## Owner decision

—
