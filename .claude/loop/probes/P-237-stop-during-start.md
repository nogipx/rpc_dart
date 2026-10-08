---
file: packages/core/rpc_dart_framework/.dart_tool/probe/r721_stop_during_start.dart
round: 721
commit: ace32ff6
paths: [packages/core/rpc_dart_framework/lib/src/rpc_app.dart]
status: valid
---

# P-237 — does RpcApp.stop() during start() leave a server running?

A module whose `onStart` takes 300 ms and a recording `IRpcServer`.
`stop()` is called 50 ms into `start()`, then once more after both settle.
Run with `melos exec --scope=rpc_dart_framework -- fvm dart run
.dart_tool/probe/r721_stop_during_start.dart`.

## Measures

The server's start and stop counts, and whether it is still running at the
end.

## Control

`stop()` after `start()` completes, and the fix's await removed:

```
  arm                       starts  stops  running
  CONTROL stop after start     1      1     false
  stop during start, no wait   1      0     true
  stop during start (r721)     1      1     false
```

Round 722 added a `two concurrent stops` arm. Server stops and module
`onStop` read 2 and 2 before that round's fix and 1 and 1 after it.
