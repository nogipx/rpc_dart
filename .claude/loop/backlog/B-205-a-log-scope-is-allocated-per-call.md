---
status: open
round: 512 (measured as part of B-121; split out in the round-540 bookkeeping pass)
commit: 6659c0ee
paths: [packages/core/rpc_dart/lib/src/logger/log_scope.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart]
probe: P-150
reason: "cost — the level lookup is now cached; the OTHER half of the lead, a scope allocated and a name concatenated per call, was never varied"
---

# B-205 — `child()` and `withContext()` allocate a scope and concatenate a name per call

Split out of B-121, which round 512 closed after caching the resolved level per scope, so
`isInternal` is no longer a linear scan over scope overrides. Bench
`../probes/P-150-what-does-a-log-guard-cost.md`.

**The half nothing varied.** `child()` and `withContext()` build a new `LogScope` and
concatenate its name on every call, at `UnaryCaller`, `StreamProcessor`, `CallProcessor`
and `_cacheContext`. That is per CALL, not per log line, so it is paid whether or not
anything is logged — and the level cache round 512 added is keyed by scope name, so a fresh
scope per call is also a fresh cache entry.

That last point is worth measuring first: the cache has a `_maxResolvedScopes` ceiling of
512, and a per-call scope name that varies would churn it. Whether these names vary per call
or per call SHAPE was not established.

## Why it matters

Allocation on every call on the hot path, and possibly a cache designed for a bounded set of
names being fed an unbounded one.

## Witness a round would build

P-150's shape with the allocation counted rather than the lookup: scopes created per call at
each of the four sites, and `_resolvedByScope`'s size across a run of many calls — which
answers the churn question at the same time.

## Owner decision

—
