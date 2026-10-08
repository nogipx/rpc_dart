---
file: packages/core/rpc_dart_framework/.dart_tool/probe/r727_rollback_order.dart
round: 727
commit: 472dd6af
paths: [packages/core/rpc_dart_framework/lib/src/rpc_app.dart, packages/core/rpc_dart_framework/lib/src/rpc_test_app.dart]
status: valid
---

# P-240 — in what order does each RpcApp teardown stop server and modules?

A recording module and a recording `IRpcServer`. The probe runs `stop()`
after a good start, then a start whose `afterModulesStart` throws. Run with
`melos exec --scope=rpc_dart_framework -- fvm dart run
.dart_tool/probe/r727_rollback_order.dart`.

## Measures

The order of `server.stop` and `module.onStop`.

## Control

`stop()`, which has stopped the server first all along:

```
  stop()                    [server.start, server.stop, module.onStop]
  rollback, before r727     [server.start, module.onStop, server.stop]
  rollback, after r727      [server.start, server.stop, module.onStop]
```
