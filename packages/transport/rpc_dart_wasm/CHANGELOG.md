<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 0.2.0

The release where the native halves were compiled and then actually RUN. The
levels find different things and the order is strict — reading < compiling <
running: reading shipped a dead-runtime report through a call that is a no-op
after boot; compiling would not have caught the 30 s boot stall; and running is
what showed that on iOS a page loaded with `baseURL: nil` cannot fetch its own
module at all.

### Fixed

- **A runtime that dies on its own answers its callers** instead of leaving them
  waiting.
- **iOS**: the runtime could not fetch its own module, and its timers recursed.
  A guest whose glue code throws cost 30 s of silence before anything was
  reported.
- **Android**: a boot failure said nothing about why; a 16 MiB message killed
  the runtime; closing a runtime with traffic in flight killed the app.
- **A running guest's failures reach the host**, and a failed handler inside the
  guest is reported at ERROR rather than info.
- **`close()` releases both channels the bridge opened.**
- **Bytes that arrive before the transport binds are buffered**, not dropped.
- The iOS privacy manifest ships with the plugin.

### Changed

- Requires rpc_dart 6. See its changelog.
- The plugin's Swift and Kotlin are type-checked by a gate
  (`melos run analyze:native`), and there is a device gate that builds and runs
  them (`melos run test:wasm:device`). Neither `analyze` nor `test` compiles a
  line of either.
- The package's `dart:js_interop` implementation is compiled for a JS target by
  `test:wasm`. It had no JS-target compile anywhere — `analyze` runs over it at
  `--fatal-infos` and is structurally incapable of seeing its one failure mode.

## 0.1.2

- fix: align `RpcWasm.run` stub signature with the real implementation. The VM/host stub (`rpc_wasm_stub.dart`) was missing the `LogController? logController` named parameter, so code calling `RpcWasm.run(logController: ...)` compiled on the WASM/JS target but failed to compile on the host/VM stub target. The stub now matches the real implementation parameter-for-parameter.

## 0.1.1

- Test coverage: added transport-contract tests against an in-memory mock bridge that loops byte frames between a host and a sandbox endpoint (the same byte loop the JS/WASM bridge performs in production).
- `rpc_wasm_endpoint_test.dart` — end-to-end `RpcCallerEndpoint`/`RpcResponderEndpoint` round-trips over `RpcWasmTransport`: unary, server/client/bidirectional streaming, ordering, concurrent calls, mid-stream cancellation without deadlock, typed `RpcStatusException` error propagation, and lifecycle (use-after-dispose fails cleanly, close cascades to the bridge).
- `rpc_wasm_transport_test.dart` — expanded with stream-id uniqueness/parity, `getMessagesForStream` filtering, send-after-close, bridge-close cascade, and byte-framing (send-to-frame mapping, byte-identical round-trip).
- Shared `test/support/fake_wasm_bridge.dart` mock bridge.
- Note: the real JS/WASM sandbox round-trip (`RpcWasm.run`, `RpcFlutterWasmBridge`) still requires a browser/device with a loaded WASM module and a native host; everything above the byte boundary is now covered without one.

## 0.1.0

- Initial release: WASM transport for rpc_dart as a Flutter plugin.
- `RpcWasmTransport` — `IRpcChannel` implementation bridging Dart↔WASM via `RpcWasmBridge`.
- `RpcFlutterWasmBridge` — Flutter plugin bridge using platform channels (Android: Kotlin, iOS: Swift) to load and run WASM modules in a sandboxed JS environment.
- `RpcWasmBridge` — pure Dart WASM bridge for non-Flutter targets.
- WASM sandbox executes widlet/plugin code in isolation; messages pass as binary frames over the bridge.
- Android: `RpcDartWasmPlugin` (Kotlin) with QuickJS-based WASM execution.
- iOS: `RpcDartWasmPlugin` (Swift) with JavaScriptCore-based WASM execution.
