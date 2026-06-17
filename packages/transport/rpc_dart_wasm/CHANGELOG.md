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
