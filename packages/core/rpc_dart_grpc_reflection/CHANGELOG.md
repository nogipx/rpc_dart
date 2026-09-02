<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 0.3.0

### Changed

- Requires rpc_dart 5. See its changelog: flow control is on by default, an
  expired deadline is now `RpcDeadlineExceededException` on every shape, and a
  stream that ends without a trailer raises `UNAVAILABLE`.

## 0.2.3

**Fixes (protobuf-wire G/E):**
- `RpcFieldType` now covers the full `FieldDescriptorProto.Type` set. Added the missing values: `typeEnum` (14) — previously absent, so enum-typed fields could not be described — plus `typeGroup` (10), `typeFixed64` (6), `typeFixed32` (7), `typeSfixed32` (15), `typeSfixed64` (16), `typeSint32` (17), `typeSint64` (18).
- Documented `ProtoWriter` as the canonical proto-wire encoder. `rpc_dart_generator` carries a byte-identical private copy (it cannot depend on this `publish_to: none` package). A new `proto_writer_parity_test.dart` pins the canonical golden bytes; the generator's parity test asserts the same goldens.

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
