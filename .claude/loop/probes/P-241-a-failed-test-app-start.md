---
file: packages/core/rpc_dart_framework/.dart_tool/probe/r728_test_app_start_rollback.dart
round: 728
commit: 6dce1742
paths: [packages/core/rpc_dart_framework/lib/src/rpc_test_app.dart, packages/core/rpc_dart_framework/lib/src/rpc_app.dart]
status: valid
---

# P-241 — does a failed start stop the modules it already started?

Module A starts, then module B's `onStart` throws, through `RpcApp` and
through `RpcTestApp`. Run with `melos exec --scope=rpc_dart_framework --
fvm dart run .dart_tool/probe/r728_test_app_start_rollback.dart`.

## Measures

How many times A's `onStop` ran.

## Control

`RpcApp`, which has rolled back all along:

```
  RpcApp                    1
  RpcTestApp, before r728   0
  RpcTestApp, after r728    1
```
