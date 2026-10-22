---
file: packages/core/rpc_dart/.dart_tool/probe/r891_backoff/probe.dart
round: 891
commit: ae07b025
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: stale (6967b453)
promoted: no — what it measures is process exit, which a test inside the runner cannot see; the disconnect half is witnessed by test/resilience/a_stop_wakes_the_backoff_sleep_test.dart
---

# P-343 — r891 exit after dispose mid backoff

## Measures

Milliseconds from `dispose()` returning to the process exiting, run through
`run.py` (same directory) which times the child from its `DISPOSED` line. ARM
(`arm`): a factory that always throws, `ExponentialBackoff(baseDelay: 5 s,
jitter: false)`, dispose() 100 ms into attempt 2's backoff. Before: 4905,
4908 ms. After: 11-13 ms.

## Control

`control`: the factory succeeds, dispose() once Online: 12-14 ms on every run.
