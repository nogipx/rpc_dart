---
file: packages/transport/rpc_dart_wasm/test/a_foreign_runtime_is_released_quietly_test.dart
round: 744
commit: 8c0e7531
paths: [packages/transport/rpc_dart_wasm/lib/src/rpc_flutter_wasm_bridge.dart]
status: valid
---

# P-248 — does releasing a foreign runtime leak an error?

A mocked `rpc_dart_wasm` MethodChannel answers `loadRuntime` with a runtime id
other than the one requested. `RpcFlutterWasmBridge.load()` must fail with
UNAVAILABLE and release that runtime. In the witness arm the mock's
`closeRuntime` throws a `PlatformException`. Run with `fvm flutter test --no-pub
test/a_foreign_runtime_is_released_quietly_test.dart` in
`packages/transport/rpc_dart_wasm`.

## Measures

Whether the test passes; flutter_test fails a test on an uncaught async error
and prints its stack.

## Control

The same load with a `closeRuntime` that succeeds: UNAVAILABLE, and one
`closeRuntime` call carrying the foreign id.
