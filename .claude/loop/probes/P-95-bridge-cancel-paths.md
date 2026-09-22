---
file: packages/core/rpc_dart/.dart_tool/probe/bridge_cancel_paths.dart
round: 425
commit: 6b59f2d6
paths: [packages/core/rpc_dart/lib/src/core/stream_bridge.dart, packages/core/rpc_dart/lib/src/contracts/call_scope.dart, packages/core/rpc_dart/lib/src/resilience/circuit_breaker_interceptor.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
status: valid
---

# P-95 — how long a consumer's cancel() takes on a bridge over a parked source

`fvm dart run packages/core/rpc_dart/.dart_tool/probe/bridge_cancel_paths.dart`.

Five arms, each: subscribe to a bridged stream whose source is a user `async*`
suspended at an `await` that never completes, then time `sub.cancel()` with a
3000 ms cap. `-1` prints as `HUNG`. For another bridge, add an arm — the source
and the timer are shared, only the site under test changes.

## Measures

Milliseconds from the CONSUMER's `cancel()` to its completion, on the consumer
side of the bridge. `StreamController` awaits whatever `onCancel` returns, so
this number is the consumer's exposure to the source's own teardown.

## Control

Arm 3 is the mechanism removed: the same parked source through a hand-built
controller whose `onCancel` drops the cancel Future instead of returning it.
Arms 4 and 5 are the real code paths with the defect absent — a source that
does not park, and site 6's bridge, which already had the clause.

```
                             before      after the fix
1 track(parked)              HUNG        8ms
2 breaker(parked)            HUNG        5ms
3 CONTROL unawaited(parked)  6ms         6ms
4 CONTROL track(prompt)      7ms         6ms
5 CONTROL site 6 bridge      7ms         6ms
```

Arm 3 at 6 ms against arms 1-2 hung is what makes the bench valid: the park
alone does not produce the number, the await does.
