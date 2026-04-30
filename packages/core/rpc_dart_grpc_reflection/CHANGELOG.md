## 0.1.0

- Initial release: gRPC Server Reflection v1 and v1alpha for rpc_dart.
- `RpcReflectionRegistry` — service descriptor registry with two registration tiers:
  - Tier 1 (protobuf): `addFromPbjson()` using bytes from generated `.pbjson.dart`
  - Tier 2 (codegen): `addFileDescriptor(MyServiceNames.grpcDescriptor)`
- `RpcReflectionRegistry.attachTo(endpoint)` — registers v1 + v1alpha reflection contracts in one call.
- `ServerReflectionContract` — bidi-streaming contract implementing the reflection protocol via hand-written protobuf binary encoder/parser (no `package:protobuf` dependency).
- `RpcFileDescriptorBuilder` — builds `FileDescriptorProto` from `RpcMessageDescriptor` / `RpcServiceDescriptor` or raw bytes.
