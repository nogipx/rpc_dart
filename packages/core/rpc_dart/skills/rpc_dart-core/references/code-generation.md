<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Contracts by code generation (recommended)

Write one annotated abstract interface; `rpc_dart_generator` generates the
typed caller, the responder base class, the method-name constants and the
codecs. This is the recommended way to define a service. Write contracts by hand
(`contracts-and-endpoints.md`) only when you cannot run `build_runner`.

Why generate:

- The caller and the responder come from ONE declaration, so their service
  name, method names, kinds and codecs cannot drift apart.
- The request and response types are checked against the transfer mode at
  build time. A hand-written contract finds a missing codec when a call fails
  on a network transport.
- Versioned services (a new interface that `implements` the old one) get
  delegation and `@RpcRemoved` handling for free.

## Setup

```yaml
dependencies:
  rpc_dart: ^6.3.0

dev_dependencies:
  build_runner: ^2.11.1
  rpc_dart_generator: ^0.6.0
```

The builder applies itself to every package that depends on it and takes no
options. The annotations live in `package:rpc_dart`, so the interface compiles
without the generator.

## Rules

- Annotate an **abstract** class with `@RpcService(name: ...)`. `name` is the
  wire service name.
- Annotate every method with `@RpcMethod.unary`, `.serverStream`,
  `.clientStream` or `.bidirectionalStream`, each with a `name:` unique within
  the service.
- Every method takes exactly ONE positional request parameter and the named
  `{RpcContext? context}`. Declare `context` on every method: a method without
  it generates a responder that does not compile.
- Signatures must match the kind:

  | Kind | Signature |
  | --- | --- |
  | unary | `Future<Res> m(Req request, {RpcContext? context})` |
  | serverStream | `Stream<Res> m(Req request, {RpcContext? context})` |
  | clientStream | `Future<Res> m(Stream<Req> requests, {RpcContext? context})` |
  | bidirectionalStream | `Stream<Res> m(Stream<Req> requests, {RpcContext? context})` |

- In `auto` (the default) and `codec` mode every request and response type is
  `IRpcSerializable` with a `fromJson(Map<String, dynamic>)` factory, or one of
  `String`, `int`, `double`, `bool`, `Map<String, dynamic>`. `RpcString`,
  `RpcInt` and the other core primitives qualify.
- Add `part '<file>.g.dart';` to the file. Generation writes there.
- Generated names drop a leading `I` followed by a capital letter:
  `IGreeterContract` gives `GreeterContractCaller`,
  `GreeterContractResponder`, `GreeterContractNames`,
  `GreeterContractCodecs`.

## The interface

```dart
@RpcService(name: 'Greeter')
abstract class IGreeterContract {
  @RpcMethod.unary(name: 'hello')
  Future<RpcString> hello(RpcString request, {RpcContext? context});

  @RpcMethod.serverStream(name: 'countdown')
  Stream<RpcInt> countdown(RpcInt from, {RpcContext? context});

  @RpcMethod.clientStream(name: 'sum')
  Future<RpcInt> sum(Stream<RpcInt> values, {RpcContext? context});
}
```

In the real file this sits under `import 'package:rpc_dart/rpc_dart.dart';` and
`part 'greeter_contract.g.dart';`.

Then generate:

```sh
fvm dart run build_runner build --delete-conflicting-outputs
# or keep it running:
fvm dart run build_runner watch --delete-conflicting-outputs
```

Never edit the `.g.dart` file by hand; change the interface and regenerate.
The builder is a `source_gen` shared-part builder, so it shares the part file
with `json_serializable` and similar generators.

## What you get

| Generated | Use |
| --- | --- |
| `GreeterContractNames` | `service` and one constant per method (the wire names); `instance(suffix)` for a second instance of the service. |
| `GreeterContractCodecs` | One `const` codec per request/response type. Present in `auto` and `codec` mode. |
| `GreeterContractCaller` | Concrete. `GreeterContractCaller(callerEndpoint, {serviceNameOverride, dataTransferMode})`; implements the interface, so every method is a typed call. |
| `GreeterContractResponder` | Abstract. Its `setup()` registers every method with the right codecs; you subclass it and implement the interface methods. |

Using them. This block depends on the generated part, so it is shown without
being compiled here:

```text
final class GreeterResponder extends GreeterContractResponder {
  GreeterResponder({super.serviceNameOverride});

  @override
  Future<RpcString> hello(RpcString request, {RpcContext? context}) async =>
      RpcString('Hello, ${request.value}');

  @override
  Stream<RpcInt> countdown(RpcInt from, {RpcContext? context}) async* {
    for (var i = from.value; i >= 0; i--) {
      yield RpcInt(i);
    }
  }

  @override
  Future<RpcInt> sum(Stream<RpcInt> values, {RpcContext? context}) async {
    var total = 0;
    await for (final v in values) {
      total += v.value;
    }
    return RpcInt(total);
  }
}

Future<void> main() async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(GreeterResponder())
    ..start();
  final greeter = GreeterContractCaller(RpcCallerEndpoint(transport: client));

  final reply = await greeter.hello(
    RpcString('rpc_dart'),
    context: RpcContext.withTimeout(const Duration(seconds: 5)),
  );
  print(reply.value);

  await greeter.endpoint.close();
  await responder.close();
}
```

Endpoints, transports, deadlines, errors and streaming work exactly as for a
hand-written contract; the other references apply unchanged.

## Transfer modes

`@RpcService(transferMode: ...)` sets the mode for the service (default
`RpcDataTransferMode.auto`); `@RpcMethod(transferMode: ...)` overrides one
method.

| Mode | Codecs | Types | Runtime |
| --- | --- | --- | --- |
| `auto` | generated | serializable or primitive | serializes, except unary calls on a zero-copy transport, which pass objects |
| `codec` | generated | serializable or primitive | always serializes |
| `zeroCopy` | none | any | passes objects; only on transports with `supportsZeroCopy` (`memoryPair()`, isolates) |

Use `auto` or `codec` for anything that crosses a network. `zeroCopy` fails on
any transport without `supportsZeroCopy`: HTTP/2, HTTP/1.1, WebSocket, and
`RpcChannelTransport.pair()`.

To use a codec of your own, give its `Type` (with a `const` constructor):
`@RpcMethod.unary(name: 'x', requestCodec: MyCodec, responseCodec: MyCodec)`.

## Peer services

`@RpcService(name: 'Chat', kind: RpcServiceKind.peer)` generates, instead of
Caller and Responder:

- `ChatContractPeer` (abstract): its interface methods call the REMOTE side;
  its `setup()` registers handlers named `on<Method>` (`onPing` for `ping`),
  which you implement. Register it on an `RpcPeerEndpoint`.
- `ChatContractPeerCaller`: calls only, registers nothing.

## Versioning

A new version is a new interface with a new service name that `implements` the
previous one. Annotate only what changes; mark a method that is gone with
`@RpcRemoved('message')` on an `@override`.

```dart
@RpcService(name: 'Greeter.v2')
abstract class IGreeterContractV2 implements IGreeterContract {
  @RpcRemoved('Use helloV2 instead.')
  @override
  Future<RpcString> hello(RpcString request, {RpcContext? context});

  @RpcMethod.unary(name: 'helloV2')
  Future<RpcString> helloV2(RpcString request, {RpcContext? context});
}
```

- The v2 `Responder` registers only v2's own methods. Keep the older
  responders registered on the server while old callers exist.
- The v2 `Caller` implements the whole interface: inherited methods reach the
  older service name, removed ones are `@Deprecated` and throw
  `UnsupportedError`.
- A changed response type must be a subtype of the old one, as Dart requires
  for an override.

## Pitfalls

- Forgetting `part '<file>.g.dart';`, or running nothing: the generated classes
  do not exist and every use is a compile error.
- Two methods with the same `name:` in one service: the build fails. A method
  `name` with a dot builds, then throws when the responder is registered
  (method names allow letters, digits, `_` and `-`).
- A model without a `fromJson` factory in `auto`/`codec` mode: the generated
  codec does not compile.
- `...Responder` is abstract: subclass it, implement every method, and
  register an instance of the subclass.
- `@RpcProtoField` and `grpcDescriptor: true` (gRPC reflection) are described
  in the `rpc_dart_generator` README.
