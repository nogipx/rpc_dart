<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# gRPC Server Reflection

`rpc_dart_grpc_reflection` serves the gRPC Server Reflection protocol (v1 and
v1alpha) from an rpc_dart endpoint. `grpcurl`, Postman and other gRPC tools use
it to list services and describe their methods and messages without a local
`.proto` file.

Two pieces:

- `RpcReflectionRegistry` holds `FileDescriptorProto` bytes, the protobuf
  description of your services.
- `ServerReflectionContract` is a responder contract that answers reflection
  requests from that registry. `registry.attachTo(endpoint)` registers it.

Use it when a server built on `rpc_dart_http2` should be explorable by gRPC
tooling. Reflection is plain gRPC, and only `rpc_dart_http2` speaks gRPC (see
[choosing-a-transport.md](choosing-a-transport.md)). The contract registers on
any endpoint, but over WebSocket, HTTP/1.1 or isolates no gRPC tool can reach it.

## Setup

```yaml
dependencies:
  rpc_dart: ^6.3.0
  rpc_dart_grpc_reflection: ^0.3.0
  rpc_dart_http2: ^0.3.0
```

## Rules

- The registry knows only what you add. It does not look at the contracts
  registered on the endpoint. A service without a descriptor in the registry
  is not listed, and the reflection services themselves are not listed either.
- The descriptor must match the contract: the responder's service name is the
  proto `<package>.<Service>` (`'echo.v1.EchoService'`), and its method names
  are the proto method names (`'Echo'`). Otherwise tools describe a method the
  server cannot route.
- Reflection describes a protobuf schema. A tool can CALL a method only when
  its payloads are protobuf: `RpcBinaryCodec` around `protoc`-generated
  messages. With `RpcCodec` (CBOR) the service can be listed and described, but
  a call from `grpcurl` fails with `INTERNAL`.
- Build the registry once and share it. `RpcHttp2Server` creates one endpoint
  per connection, so call `registry.attachTo(endpoint)` inside
  `onEndpointCreated`. The server starts the endpoint after the callback.
- `attachTo` registers both `grpc.reflection.v1.ServerReflection` and
  `grpc.reflection.v1alpha.ServerReflection`. Call it once per endpoint.
- A descriptor that imports other proto files needs those files registered
  too. `registry.missingDependencies()` returns the imported files that are
  not; check it at startup.

## Where descriptors come from

| Source | Register with |
| --- | --- |
| `protoc` output (`.pbjson.dart`) | `registry.addFromPbjson(name:, package:, messages:, services:, dependencies:)` with the generated `...Descriptor` byte lists |
| `rpc_dart_generator` with `@RpcService(grpcDescriptor: true)` | `registry.addFileDescriptor(<Base>Names.grpcDescriptor)` |
| Built by hand | `registry.addFileDescriptor(RpcFileDescriptorBuilder(...)...build())` |
| Any `FileDescriptorProto` bytes | `registry.addFileDescriptor(bytes)` |

## API

| Type / member | Use |
| --- | --- |
| `RpcReflectionRegistry({LogScope? logger})` | The registry. `logger` receives a warning when a response has to omit an unregistered dependency. |
| `addFileDescriptor(Uint8List)` | Register one serialized `FileDescriptorProto`. |
| `addFromPbjson({required name, required package, required messages, required services, dependencies})` | Assemble a file from `protoc` descriptor bytes. Imported files are registered separately. |
| `attachTo(RpcResponderEndpoint)` | Register both reflection contracts on the endpoint. |
| `serviceNames`, `hasDescriptors`, `missingDependencies()` | Inspection and startup checks. |
| `ServerReflectionContract(registry, {serviceName})`, `ServerReflectionContract.both(registry)` | The contracts `attachTo` registers, for registering by hand. |
| `RpcFileDescriptorBuilder(name:, package:, syntax:)` | Hand-built file. `addMessage`, `addEnum`, `addService(name:, methods:)`, `addMessageBytes`, `addServiceBytes`, `addDependency`, then `build()`. |
| `RpcMessageDescriptor`, `RpcFieldDescriptor`, `RpcEnumDescriptor`, `RpcEnumValueDescriptor`, `RpcMethodDescriptor` | Parts for the builder. Field types are `RpcFieldType` (`typeString`, `typeInt64`, ...); `RpcFieldLabel.repeated` for lists. |

Type references inside a descriptor are fully qualified with a leading dot:
`'.echo.v1.EchoRequest'`.

## Example: a hand-built descriptor on an HTTP/2 server

```dart
import 'package:rpc_dart_grpc_reflection/rpc_dart_grpc_reflection.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

final Uint8List echoDescriptor =
    RpcFileDescriptorBuilder(name: 'echo.proto', package: 'echo.v1')
        .addMessage(
          const RpcMessageDescriptor(
            name: 'EchoRequest',
            fields: [
              RpcFieldDescriptor(
                name: 'text',
                number: 1,
                type: RpcFieldType.typeString,
              ),
            ],
          ),
        )
        .addMessage(
          const RpcMessageDescriptor(
            name: 'EchoReply',
            fields: [
              RpcFieldDescriptor(
                name: 'text',
                number: 1,
                type: RpcFieldType.typeString,
              ),
            ],
          ),
        )
        .addService(
          name: 'EchoService',
          methods: [
            const RpcMethodDescriptor(
              name: 'Echo',
              inputType: '.echo.v1.EchoRequest',
              outputType: '.echo.v1.EchoReply',
            ),
          ],
        )
        .build();

/// [createEcho] builds the responder for `echo.v1.EchoService`, one per
/// connection.
Future<RpcHttp2Server> serveWithReflection(
  RpcResponderContract Function() createEcho,
) async {
  final registry = RpcReflectionRegistry()..addFileDescriptor(echoDescriptor);
  final missing = registry.missingDependencies();
  if (missing.isNotEmpty) {
    throw StateError('Unregistered proto files: $missing');
  }

  final server = RpcHttp2Server(
    host: '0.0.0.0',
    port: 50051,
    onEndpointCreated: (endpoint) {
      endpoint.registerServiceContract(createEcho());
      registry.attachTo(endpoint);
    },
  );
  await server.start();
  return server;
}
```

Then, from a shell:

```sh
grpcurl -plaintext localhost:50051 list
grpcurl -plaintext localhost:50051 describe echo.v1.EchoService
grpcurl -plaintext localhost:50051 describe echo.v1.EchoService.Echo
grpcurl -plaintext -d '{"text":"hi"}' localhost:50051 echo.v1.EchoService/Echo
```

The last command works only if the `Echo` responder uses protobuf codecs.

## Protobuf services

This is the setup under which `grpcurl` can also call methods. It needs
`protoc`-generated `echo.pb.dart` and `echo.pbjson.dart`, so it is shown
without being compiled here:

```text
final requestCodec = RpcBinaryCodec<EchoRequest>(
  toBytes: (m) => m.writeToBuffer(),
  fromBytes: EchoRequest.fromBuffer,
);
final replyCodec = RpcBinaryCodec<EchoReply>(
  toBytes: (m) => m.writeToBuffer(),
  fromBytes: EchoReply.fromBuffer,
);
// Register 'Echo' on a responder named 'echo.v1.EchoService' with these codecs.

final registry = RpcReflectionRegistry()
  ..addFromPbjson(
    name: 'echo.proto',
    package: 'echo.v1',
    messages: [echoRequestDescriptor, echoReplyDescriptor],
    services: [echoServiceDescriptor],
  );
```

## Descriptors from the generator

`@RpcService(grpcDescriptor: true)` makes `rpc_dart_generator` add a static
`grpcDescriptor` to the generated `<Base>Names` class. The everyday generator
workflow is in [code-generation.md](code-generation.md).

```dart
import 'package:rpc_dart_generator/rpc_dart_generator.dart';

final class PingRequest implements IRpcSerializable {
  const PingRequest({required this.id});

  factory PingRequest.fromJson(Map<String, dynamic> json) =>
      PingRequest(id: json['id'] as String);

  @RpcProtoField(1)
  final String id;

  @override
  Map<String, dynamic> toJson() => {'id': id};
}

@RpcService(name: 'health.v1.Pinger', grpcDescriptor: true)
abstract class IPinger {
  @RpcMethod.unary(name: 'Ping')
  Future<PingRequest> ping(PingRequest request, {RpcContext? context});
}
```

After `build_runner`, register the generated bytes. This needs the generated
part, so it is not compiled here:

```text
final registry = RpcReflectionRegistry()
  ..addFileDescriptor(PingerNames.grpcDescriptor);
```

What the generator emits:

- Proto package is the service name up to the last dot, the service is the
  rest: `health.v1.Pinger` gives package `health.v1`, service `Pinger`, file
  `health_v1_Pinger.proto`.
- One message per request and response type, built from the fields the class
  itself declares. `String` is `string`, `int` is `int64`, `double` is
  `double`, `bool` is `bool`, a `List<T>` is `repeated`, an enum is an enum
  reference, any other class a message reference.
- Field numbers follow declaration order unless pinned with `@RpcProtoField(n)`
  (from `package:rpc_dart_generator/rpc_dart_generator.dart`). The build warns
  about unpinned fields. Code that uses `@RpcProtoField` needs
  `rpc_dart_generator` in `dependencies`, not only `dev_dependencies`.

## Pitfalls

- Expecting `grpcurl list` to show every registered contract. It shows only
  services whose descriptors were added to the registry.
- Calling a CBOR service from `grpcurl` because `describe` worked. Description
  and wire format are independent; the call fails with `INTERNAL`.
- A generated service whose request or response is a core primitive
  (`RpcString`, `RpcInt`, ...) or a Dart built-in. The descriptor is built from
  the fields the class declares, and those types declare none or unrelated
  ones: no `grpcDescriptor` is generated, or it describes the wrong fields. Use
  your own model classes.
- A model field of type `Map`, `Set` or `Iterable` in a generated service. The
  build warns and the field is left out of the descriptor.
- A model field whose type is another model class. Only request and response
  types become messages; the nested type is referenced but not described.
- Imported proto files left out of the registry. Responses then omit them, a
  warning is logged, and tools cannot resolve the types. Check
  `missingDependencies()` at startup.
- Registering reflection on a WebSocket or HTTP/1.1 server and pointing
  `grpcurl` at it. Only `rpc_dart_http2` serves gRPC.

The full reference is the `rpc_dart_grpc_reflection` README; the generator's
descriptor options are in the `rpc_dart_generator` README.
