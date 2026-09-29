---
round: 512
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-150 — new
commit: yes
---

# Round 512 — the guard that was not a bool read

## Target

`LogScope.isInternal` — twenty-eighth in the audit's rank, the third COST-class lead
of the run.

Lens RPC-17, in round 511's reading: ask what the work is FOR. This one is sharper
than usual, because the work exists to AVOID work. A guard whose whole purpose is to
be cheaper than the thing it guards.

## Hypothesis

`isInternal` walks the configured scope overrides with a `startsWith` per entry on
every call, while `CLAUDE.md` describes it as a bool read.

## Before

```
0 scope overrides                     21.8 ns/guard
20 scope overrides                   235.5 ns/guard
CONTROL LogScope.noop (a real bool)    1.8 ns/guard
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b121_guard_cost.dart`

**CONFIRMED.** 128x a bool read at twenty overrides, and the cost grows with however
many the application configured.

The control is what gives the number scale. `LogScope.noop`'s `isInternal` is a
literal `false`, so 1.8 ns is what the thing CLAUDE.md describes actually costs.

## Mechanism

```dart
for (final entry in _scopeLevels.entries) {
  if (scope.startsWith(entry.key) && entry.key.length > bestLength) { ... }
}
```

A longest-prefix match, recomputed per call. The overrides change approximately
never; the guard runs at hundreds of sites.

## After

```
0 scope overrides                     18.7 / 21.1 ns/guard
20 scope overrides                    12.9 / 12.6 ns/guard
CONTROL LogScope.noop                  1.8 /  1.9 ns/guard
```

Resolution cached per scope name. 18x at twenty overrides, and **flat** — the two
after-figures differ only by noise, so the cost no longer depends on configuration.

**Keyed by scope alone**, although resolution also takes a tag: a tag override is an
O(1) map read taken BEFORE the cache, so when it misses the answer depends on the
scope only. That keeps one map instead of a composite key, and means tag changes need
no invalidation at all.

**`minLevel` is the awkward one and drove the design.** It is a public mutable field,
so nothing calls a setter that could clear the cache. The cache remembers which
`minLevel` it was built under and discards itself when that differs — one comparison
per lookup instead of a correctness bug, and no API change.

Bounded at 512 entries and cleared wholesale, because `child()` concatenates names,
so a caller creating many short-lived scopes would otherwise grow it without limit.
Clearing rather than evicting keeps the lookup a plain map read.

Regression: `test/logger/the_level_cache_never_goes_stale_test.dart`, 10 tests.

## Canary

**Two ablations, because the fix introduces a risk the defect did not have.**

1. **Cache bypassed.** The bench returns to `250.1 ns` at twenty overrides — and all
   ten tests still pass. That is the finding about the tests: the scanning version
   was correct, so nothing here witnesses the defect. They were labelled WITNESS in
   the first draft and this ablation corrected it. Every test in the file is a GUARD
   and it now says so.
2. **Invalidation removed.** Four tests fail — adding an override, changing one,
   clearing one, and assigning `minLevel` — each with the stale answer:
   `Expected: true, Actual: <false>`. Including the `minLevel` case, which is the one
   with no hook and the reason the design remembers what it was built under.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**The guard is still 7x a bool read, and CLAUDE.md's description is still not
literally true.** 12.6 ns against 1.8 ns: the tag check, the `minLevel` comparison
and the map lookup are not free. Closing that gap means caching on the `LogScope`
rather than the controller, which needs an invalidation path from controller to every
scope it has issued — much more machinery for ~11 ns.

**Most deployments never paid this.** The library's idiom is
`_log = logger ?? LogScope.noop`, so an application that configures no logger gets
the 1.8 ns path everywhere. What this fixes is the instrumented build with overrides
configured — which is the case the guard exists for, so it is the right one to fix,
but the record should not imply every user was paying 235 ns.

**The lead's other half is untouched:** `child()` and `withContext()` allocate a new
scope and concatenate names per call, at `UnaryCaller`, `StreamProcessor`,
`CallProcessor` and `_cacheContext`. Nothing here was varied on that.

## Links

Lens RPC-17. Bench P-150 (new). Lead B-121 (closed on the `isInternal` half).
