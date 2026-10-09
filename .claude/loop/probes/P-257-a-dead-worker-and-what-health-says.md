---
file: packages/core/rpc_dart_framework/.dart_tool/probe/r752_dead_worker.dart
round: 752
commit: f031102c
paths: [packages/core/rpc_dart_framework/lib/src/rpc_isolate_module.dart, packages/core/rpc_dart_framework/lib/src/rpc_app.dart, packages/core/rpc_dart_framework/lib/src/rpc_test_app.dart]
status: valid
---

# P-257 — a dead worker and what health says

An `RpcTestApp` with one `RpcIsolateModule`. The worker serves `Work/Echo`
and `Work/Die`; `Die` calls `Isolate.exit()`. The main isolate proxies both as
`Svc/*`. Run from the repo root:
`fvm dart run packages/core/rpc_dart_framework/.dart_tool/probe/r752_dead_worker.dart <arm>`.

- `control`: the worker stays alive.
- `die`: one `Svc/Die` call, then the same steps as `control`.

## Measures

The setup check first (an `Echo` before anything, L-15), then after 500 ms:
whether the worker transport is closed, three `Echo` outcomes (value or gRPC
status), and `app.health()`'s level and module map.

## Control

`control` and `die` differ only in the `Die` call. `control` reads `ok x` and
`healthy` throughout, so the bench separates a live worker from a dead one.
