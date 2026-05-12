## 0.1.0

- Initial release: WASM transport for rpc_dart as a Flutter plugin.
- `RpcWasmTransport` — `IRpcChannel` implementation bridging Dart↔WASM via `RpcWasmBridge`.
- `RpcFlutterWasmBridge` — Flutter plugin bridge using platform channels (Android: Kotlin, iOS: Swift) to load and run WASM modules in a sandboxed JS environment.
- `RpcWasmBridge` — pure Dart WASM bridge for non-Flutter targets.
- WASM sandbox executes widlet/plugin code in isolation; messages pass as binary frames over the bridge.
- Android: `RpcDartWasmPlugin` (Kotlin) with QuickJS-based WASM execution.
- iOS: `RpcDartWasmPlugin` (Swift) with JavaScriptCore-based WASM execution.
