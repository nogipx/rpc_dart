<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_grpc_reflection

gRPC Server Reflection (v1 and v1alpha) for `rpc_dart`, so `grpcurl`, Postman
and other gRPC tooling can list and describe the services of an endpoint.

- `RpcReflectionRegistry` — holds the `FileDescriptorProto` bytes to serve.
  `attachTo(endpoint)` registers the reflection service on an endpoint.
- `ServerReflectionContract` — the responder contract that answers reflection
  requests. `attachTo` registers two of them (`ServerReflectionContract.both`):
  `grpc.reflection.v1.ServerReflection` and
  `grpc.reflection.v1alpha.ServerReflection`.
- Descriptor sources:
  - `addFromPbjson(...)` — descriptor bytes from `protoc`-generated
    `.pbjson.dart`.
  - `addFileDescriptor(bytes)` — any serialized `FileDescriptorProto`, such as
    `<Base>Names.grpcDescriptor` emitted by `rpc_dart_generator` for
    `@RpcService(grpcDescriptor: true)`.
  - `RpcFileDescriptorBuilder` with `RpcMessageDescriptor`,
    `RpcMethodDescriptor`, ... — hand-written schemas.

The registry serves only what is added to it. It does not read the contracts
registered on the endpoint, so a service without a descriptor is not listed.

## Usage

```dart
import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';

final registry = RpcReflectionRegistry()..addFileDescriptor(descriptorBytes);
final missing = registry.missingDependencies(); // imported files not added

// Register your own contracts first, then reflection.
responderEndpoint.registerServiceContract(myResponderContract);
registry.attachTo(responderEndpoint);
```

With `RpcHttp2Server`, build the registry once and call `attachTo` inside
`onEndpointCreated`; the server creates one endpoint per connection.
Runnable servers are in `example/server.dart` (hand-built descriptor) and
`example/server_protobuf.dart` (`protoc` descriptors and protobuf codecs).

## Caveat

Reflection describes a **protobuf** schema. It is only truthful when the
payloads on the wire really are protobuf — i.e. when the contract uses
`RpcBinaryCodec` with `protoc`-generated messages. With the default CBOR codec
(`RpcCodec`) the descriptors are advisory: tools list and describe the service,
but a call from `grpcurl` sends protobuf the server cannot parse and fails with
`INTERNAL`.
