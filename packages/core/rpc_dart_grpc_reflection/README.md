<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_grpc_reflection

gRPC Server Reflection (v1 and v1alpha) for `rpc_dart`, so `grpcurl`, Postman
and other gRPC tooling can discover the services registered on an endpoint.

- `ServerReflectionContract` — the responder contract to register on an endpoint.
- `RpcReflectionRegistry` — holds the `FileDescriptorProto` bytes to serve.
- Descriptor builders (`RpcMessageDescriptor`, `RpcMethodDescriptor`, ...) for
  hand-written schemas; `rpc_dart_generator` can emit the same bytes from an
  annotated contract.

## Usage

```dart
import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';

final registry = RpcReflectionRegistry()..addFileDescriptor(descriptorBytes);
responderEndpoint.registerServiceContract(ServerReflectionContract(registry));
```

## Caveat

Reflection describes a **protobuf** schema. It is only truthful when the
payloads on the wire really are protobuf — i.e. when the contract uses
`RpcBinaryCodec` with `protoc`-generated messages. With the default CBOR codec
the descriptors are advisory: tools will list and describe the service, but
cannot decode the payloads.
