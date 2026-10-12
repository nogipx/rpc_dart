---
file: packages/transport/rpc_dart_isolate/.dart_tool/probe/r860_failed_startup_under_load.dart
round: 860
commit: 4150bad9
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart, packages/transport/rpc_dart_isolate/test/support/exits_after_failed_startup.dart]
status: valid
promoted: packages/transport/rpc_dart_isolate/test/audit/startup_failure_releases_the_isolate_test.dart
---

# P-327 — a failed isolate startup under load

`fvm dart run <file> <n>` from `packages/transport/rpc_dart_isolate`.
Starts `n` copies of `test/support/exits_after_failed_startup.dart` at once
(a worker that never becomes ready, `startupTimeout` 500 ms) and prints, for
each, whether it exited within 90 s, its total time, and the time from its
"spawn threw" line to its exit.

## Measures

Whether a process whose isolate spawn timed out can still end, and how
much of its lifetime is start-up (compiling and spawning) against
teardown.

## Control

`teardownStartup()` removed from the ready-timeout path: both of `n = 2`
read `HUNG >90 s`.
