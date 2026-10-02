---
round: 608
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-215 — new
budget: probes 0/5, canaries 0/5
commit: yes
release: none
---

# Round 608 — a third of a percent

## Target

B-205, the half of B-121 nothing varied: `child()` and `withContext()` allocate a
`LogScope` and concatenate a name on every call. The lead asked two things — whether
the names churn the 512-entry level cache, and what the allocation costs.

## Hypothesis

The per-call derivation is a measurable share of a call, or its names vary per call
and churn the cache.

## Before

```
five scopes, as one unary call derives      228 ns
one unary call over memoryPair            66801 ns
share                                      0.34 %
```

Medians of five runs. Probe:
`packages/core/rpc_dart/.dart_tool/probe/b205_what_a_scope_costs.dart`.

Names, by reading every derivation site: the stream shapes use fixed literals
(`UnaryCaller`, `StreamProcessor`, `CallProcessor`, …) and `_cacheContext` uses the
registered method key or `'unknown'`. The set is bounded by the registered methods,
so it cannot churn `_maxResolvedScopes` short of an application registering 512
methods.

## Control

The whole call is the denominator: a change that mattered would have to move a
number of 66.8 µs, and the derivation is 228 ns of it.

## Mechanism

n/a — the allocation is real and too small to be worth a cache of its own.

## After

n/a — no change.

## Canary

n/a — no fix.

## Gate

Not run: `lib/` and `test/` byte-identical to the previous commit.

## Not fixed

Nothing in B-205.

## Links

Lead `../backlog/B-205-a-log-scope-is-allocated-per-call.md` — closed.
Negative `../checked/C-64-per-call-log-scopes-are-noise.md` — new.
Bench `../probes/P-215-what-a-scope-costs.md` — new.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [608]`.
