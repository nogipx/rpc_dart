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
