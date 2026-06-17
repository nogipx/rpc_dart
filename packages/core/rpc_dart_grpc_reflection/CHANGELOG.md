## 0.2.2

**Fixes (backlog #7 — partial-deps were dropped silently):**
- `RpcReflectionRegistry` now emits a WARNING naming every declared dependency file that is referenced but not registered, instead of silently truncating the reflection response. The partial descriptor set is still returned (non-breaking); a reflection client now has a clear signal when its descriptor set is incomplete.
- The warning is routed through an injectable `LogScope` (new optional `RpcReflectionRegistry({LogScope? logger})` constructor) so it flows through the application's `LogController`; when no logger is injected it falls back to a console-backed default.
- Added `RpcReflectionRegistry.missingDependencies()` — reports the set of unregistered declared dependencies across the registry, for use as a startup completeness assertion.

**Cross-platform:**
- Verified web (dart2js) clean: full test suite passes under `dart test -p node`. Reflection's `async*`/`await for` handler is purely reactive (one response per request, no independent producer), so the long-lived bidi cancel-deadlock pattern does not apply. Varint decode/encode confirmed JS-safe (hi/lo 32-bit recombination retained).

## 0.2.1

**Fixes (audit):**
- `readLenDelimited` now validates `length >= 0 && pos + length <= bytes.length` before slicing -- a truncated descriptor throws a typed `FormatException` instead of a raw `RangeError`.
- Varint decoding is now JS-safe for full 64-bit values (hi/lo 32-bit recombination) instead of an overflowing native `<< shift` on dart2js.
- `ServerReflectionRequest` parsing now returns a malformed-request error response on an unknown wire type (e.g. groups) instead of silently dispatching a partial parse as a valid lookup.

## 0.2.0

- Full proto support: nested message types, nested enums, cross-file dependencies.
- Added `RpcEnumDescriptor` and `RpcEnumValueDescriptor` for registering enum schemas in `RpcFileDescriptorBuilder`.
- `RpcFileDescriptorBuilder.addDependency(protoFilename)` — declare proto import dependencies for correct cross-file symbol resolution.
- `RpcReflectionRegistry`: `fileByFilename` and `fileContainingSymbol` now transitively resolve and include all dependencies in the response.
- `ServerReflectionContract.both()` — convenience factory returning both v1 and v1alpha contracts.
- Updated to `rpc_dart: ^3.1.0`.

## 0.1.0

- Initial release: gRPC Server Reflection v1 and v1alpha for rpc_dart.
- `RpcReflectionRegistry` — service descriptor registry with two registration tiers:
  - Tier 1 (protobuf): `addFromPbjson()` using bytes from generated `.pbjson.dart`
  - Tier 2 (codegen): `addFileDescriptor(MyServiceNames.grpcDescriptor)`
- `RpcReflectionRegistry.attachTo(endpoint)` — registers v1 + v1alpha reflection contracts in one call.
- `ServerReflectionContract` — bidi-streaming contract implementing the reflection protocol via hand-written protobuf binary encoder/parser (no `package:protobuf` dependency).
- `RpcFileDescriptorBuilder` — builds `FileDescriptorProto` from `RpcMessageDescriptor` / `RpcServiceDescriptor` or raw bytes.
