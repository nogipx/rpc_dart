<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_generator

Code generator for [rpc_dart]. You write an annotated abstract interface;
`build_runner` generates the typed caller, the responder base class, the method
name constants and the codecs.

The annotations (`@RpcService`, `@RpcMethod`, `@RpcRemoved`) are part of
`package:rpc_dart`. This package only reads them. How to run the generated
contracts on endpoints and transports is documented in [rpc_dart].

## Install

```yaml
dependencies:
  rpc_dart: ^6.3.0

dev_dependencies:
  build_runner: ^2.11.1
  rpc_dart_generator: ^0.6.0
```

The builder applies itself to every package that depends on it. It takes no
options.

## Define a contract

```dart
// lib/calculator_contract.dart
import 'package:rpc_dart/rpc_dart.dart';

part 'calculator_contract.g.dart';

@RpcService(name: 'Calculator')
abstract class ICalculatorContract {
  @RpcMethod.unary(name: 'add')
  Future<AddResponse> add(AddRequest request, {RpcContext? context});

  @RpcMethod.serverStream(name: 'countUp')
  Stream<CountResponse> countUp(CountRequest request, {RpcContext? context});
}

class AddRequest implements IRpcSerializable {
  AddRequest({required this.a, required this.b});
  final int a;
  final int b;

  factory AddRequest.fromJson(Map<String, dynamic> json) =>
      AddRequest(a: json['a'] as int, b: json['b'] as int);

  @override
  Map<String, dynamic> toJson() => {'a': a, 'b': b};
}

class AddResponse implements IRpcSerializable {
  AddResponse({required this.result});
  final int result;

  factory AddResponse.fromJson(Map<String, dynamic> json) =>
      AddResponse(result: json['result'] as int);

  @override
  Map<String, dynamic> toJson() => {'result': result};
}

class CountRequest implements IRpcSerializable {
  CountRequest({required this.upTo});
  final int upTo;

  factory CountRequest.fromJson(Map<String, dynamic> json) =>
      CountRequest(upTo: json['upTo'] as int);

  @override
  Map<String, dynamic> toJson() => {'upTo': upTo};
}

class CountResponse implements IRpcSerializable {
  CountResponse({required this.value});
  final int value;

  factory CountResponse.fromJson(Map<String, dynamic> json) =>
      CountResponse(value: json['value'] as int);

  @override
  Map<String, dynamic> toJson() => {'value': value};
}
```

`@RpcMethod` has a named constructor per kind: `.unary`, `.serverStream`,
`.clientStream`, `.bidirectionalStream`. The plain constructor takes `kind`
explicitly; `kind` is required there.

Method signatures must match the kind:

| Kind | Signature |
| --- | --- |
| unary | `Future<Res> m(Req request, {RpcContext? context})` |
| serverStream | `Stream<Res> m(Req request, {RpcContext? context})` |
| clientStream | `Future<Res> m(Stream<Req> requests, {RpcContext? context})` |
| bidirectionalStream | `Stream<Res> m(Stream<Req> requests, {RpcContext? context})` |

Generation fails when:

- a method has no request parameter, more than one positional parameter, or an
  optional one;
- a named parameter other than `context` is present, or `context` is not
  `RpcContext?`;
- the return type or request type does not match the kind;
- two methods in one service share an RPC `name`;
- in `auto` or `codec` mode, a request or response type is neither
  `IRpcSerializable` nor `String`, `int`, `double`, `bool` or
  `Map<String, dynamic>`.

Declare `{RpcContext? context}` on every method. The generator accepts a method
without it, but the generated responder then does not compile.

## Generate

```sh
fvm dart run build_runner build
# or
fvm dart run build_runner watch
```

The output goes into the file named by the `part` directive
(`calculator_contract.g.dart`). The builder is a `source_gen` shared-part
builder, so its output is merged with other generators that target the same
file, such as `json_serializable`.

Generated class names drop a leading `I` from the interface name when it is
followed by a capital letter: `ICalculatorContract` becomes
`CalculatorContract*`.

## What is generated

For a unidirectional service (the default `kind`) there are up to four classes.

### `CalculatorContractNames`

Service and method name constants. Each method constant is named after the Dart
method and holds the RPC `name`.

```dart
class CalculatorContractNames {
  const CalculatorContractNames._();
  static const service = 'Calculator';
  static String instance(String suffix) => '$service\_$suffix';
  static const add = 'add';
  static const countUp = 'countUp';
}
```

### `CalculatorContractCodecs`

Present when at least one method uses `auto` or `codec` mode. One `const` codec
per distinct request/response type:

```dart
class CalculatorContractCodecs {
  const CalculatorContractCodecs._();
  static const codecAddRequest = RpcCodec<AddRequest>.withDecoder(
    AddRequest.fromJson,
  );
  static const codecAddResponse = RpcCodec<AddResponse>.withDecoder(
    AddResponse.fromJson,
  );
  // codecCountRequest, codecCountResponse
}
```

`IRpcSerializable` types need a `fromJson(Map<String, dynamic>)` factory, which
the codec references. `String`, `int`, `double`, `bool` and
`Map<String, dynamic>` get a CBOR `RpcBinaryCodec` instead. A codec type given
in `@RpcMethod(requestCodec: ..., responseCodec: ...)` is instantiated with its
`const` constructor in place of the default.

### `CalculatorContractCaller`

A concrete class. Use it directly.

```dart
class CalculatorContractCaller extends RpcCallerContract
    implements ICalculatorContract {
  CalculatorContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto,
  });
  // add() calls callUnary, countUp() calls callServerStream,
  // both with CalculatorContractCodecs.
}
```

### `CalculatorContractResponder`

An abstract class whose `setup()` registers every method. You implement the
interface methods.

```dart
abstract class CalculatorContractResponder extends RpcResponderContract
    implements ICalculatorContract {
  CalculatorContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto,
  });

  @override
  void setup() {
    addUnaryMethod<AddRequest, AddResponse>(
      methodName: CalculatorContractNames.add,
      handler: add,
      requestCodec: CalculatorContractCodecs.codecAddRequest,
      responseCodec: CalculatorContractCodecs.codecAddResponse,
    );
    addServerStreamMethod<CountRequest, CountResponse>(
      methodName: CalculatorContractNames.countUp,
      handler: countUp,
      requestCodec: CalculatorContractCodecs.codecCountRequest,
      responseCodec: CalculatorContractCodecs.codecCountResponse,
    );
  }
}
```

The default of `dataTransferMode` in both constructors is the service's
`transferMode`. A method's `description` is passed to its `add*Method` call.

### Using them

```dart
class CalculatorResponder extends CalculatorContractResponder {
  CalculatorResponder({super.serviceNameOverride});

  @override
  Future<AddResponse> add(AddRequest request, {RpcContext? context}) async =>
      AddResponse(result: request.a + request.b);

  @override
  Stream<CountResponse> countUp(
    CountRequest request, {
    RpcContext? context,
  }) async* {
    for (var i = 1; i <= request.upTo; i++) {
      yield CountResponse(value: i);
    }
  }
}

Future<void> main() async {
  final (client, server) = RpcChannelTransport.memoryPair();

  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(CalculatorResponder())
    ..start();

  final caller = CalculatorContractCaller(RpcCallerEndpoint(transport: client));
  final sum = await caller.add(AddRequest(a: 2, b: 3));
  print(sum.result); // 5

  await caller.endpoint.close();
  await responder.close();
}
```

Endpoints, transports, contexts, errors and streaming are documented in
[rpc_dart].

### Several instances of one service

`serviceNameOverride` registers or calls the same contract under another name.
`Names.instance(suffix)` builds one:

```dart
final beta = CalculatorContractNames.instance('beta'); // 'Calculator_beta'
responderEndpoint.registerServiceContract(
  CalculatorResponder(serviceNameOverride: beta),
);
final betaCaller = CalculatorContractCaller(
  callerEndpoint,
  serviceNameOverride: beta,
);
```

A responder subclass that should support this forwards `serviceNameOverride`
to `super`, as `CalculatorResponder` above does.

## Transfer modes

`@RpcService(transferMode: ...)` sets the mode for the whole service; the
default is `RpcDataTransferMode.auto`. `@RpcMethod(transferMode: ...)`
overrides it for one method.

| Effective mode | Codecs generated | Type check | Runtime |
| --- | --- | --- | --- |
| `auto` | yes | `IRpcSerializable` or primitive | serializes, except unary calls on a zero-copy transport, which pass objects |
| `codec` | yes | `IRpcSerializable` or primitive | always serializes |
| `zeroCopy` | no | none, any type | passes objects; works only on transports with `supportsZeroCopy` |

Use `zeroCopy` for contracts that never leave the process
(`RpcChannelTransport.memoryPair()`, isolates). Network transports need codecs,
so use `auto` or `codec` there. The runtime rules per transport are in
[rpc_dart].

### Models with json_serializable

The generator only needs `IRpcSerializable` and a `fromJson` factory, so
`json_serializable` models work in `auto` and `codec` mode:

```dart
@JsonSerializable()
class SumRequest implements IRpcSerializable {
  SumRequest({required this.values});
  final List<double> values;

  factory SumRequest.fromJson(Map<String, dynamic> json) =>
      _$SumRequestFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$SumRequestToJson(this);
}
```

Both generators write into the same `part` file. In `zeroCopy` mode the
`implements IRpcSerializable` is not needed.

## Peer services

`@RpcService(kind: RpcServiceKind.peer)` generates a contract for an
`RpcPeerEndpoint`, where either side can call the other over one transport.
Instead of Caller and Responder you get:

- `ChatContractPeer` (abstract): its interface methods call the remote side,
  and `setup()` registers abstract handlers named `on<Method>`, which you
  implement. Handlers always take `{RpcContext? context}`.
- `ChatContractPeerCaller`: calls only, registers nothing.

```dart
@RpcService(name: 'Chat', kind: RpcServiceKind.peer)
abstract class IChatContract {
  @RpcMethod.unary(name: 'ping')
  Future<RpcString> ping(RpcString request, {RpcContext? context});
}

class ChatPeer extends ChatContractPeer {
  ChatPeer(super.endpoint);

  @override
  Future<RpcString> onPing(RpcString request, {RpcContext? context}) async =>
      RpcString('pong ${request.value}');
}

Future<void> chat() async {
  final (a, b) = RpcChannelTransport.memoryPair();
  final left = RpcPeerEndpoint(transport: a);
  final right = RpcPeerEndpoint(transport: b);
  final leftChat = ChatPeer(left);
  left
    ..registerServiceContract(leftChat)
    ..start();
  right
    ..registerServiceContract(ChatPeer(right))
    ..start();

  final reply = await leftChat.ping(RpcString('hi')); // handled by right
  print(reply.value); // pong hi
}
```

Both constructors take `(RpcPeerEndpoint endpoint, {serviceNameOverride,
dataTransferMode})`; `dataTransferMode` applies to both directions.

## Versioning

A new contract version is a new service that `implements` the previous
interface. Each version gets its own service name, and each version's
`Responder` handles only the methods that version declares.

```dart
@RpcService(name: 'Calculator')
abstract class ICalculatorContract {
  @RpcMethod.unary(name: 'sum')
  Future<SumResponse> sum(SumRequest request, {RpcContext? context});

  @RpcMethod.serverStream(name: 'numbers')
  Stream<SumResponse> numbers(SumRequest request, {RpcContext? context});
}

// Changes the response of sum; numbers is inherited.
@RpcService(name: 'Calculator.v2')
abstract class ICalculatorContractV2 implements ICalculatorContract {
  @override
  @RpcMethod.unary(name: 'sum')
  Future<SumResponseV2> sum(SumRequest request, {RpcContext? context});
}

// Adds multiply.
@RpcService(name: 'Calculator.v3')
abstract class ICalculatorContractV3 implements ICalculatorContractV2 {
  @RpcMethod.unary(name: 'multiply')
  Future<SumResponse> multiply(SumRequest request, {RpcContext? context});
}

// Removes sum.
@RpcService(name: 'Calculator.v4')
abstract class ICalculatorContractV4 implements ICalculatorContractV3 {
  @RpcRemoved('Use multiply() instead.')
  @override
  Future<SumResponseV2> sum(SumRequest request, {RpcContext? context});
}
```

An overriding method must still be a valid Dart override, so a changed response
type has to be a subtype of the old one (here `SumResponseV2 extends
SumResponse`).

What the generator does with a contract whose parent is an `@RpcService`:

- `Names` and the `Responder`'s `setup()` contain only the methods annotated
  with `@RpcMethod` in this interface. The `Responder` does not implement the
  interface; it declares just those methods as abstract.
- The `Caller` implements the whole interface. Its own methods call this
  version's service; inherited methods delegate to the parent's `Caller`, which
  is created on the same endpoint with the parent's service name.
  `CalculatorContractV4Caller.numbers` reaches `Calculator`, `multiply` reaches
  `Calculator.v3`.
- A method marked `@RpcRemoved(message)` is not registered and not delegated.
  In the `Caller` it is `@Deprecated(message)` and throws
  `UnsupportedError(message)`. A version that only removes methods has no
  `@RpcMethod` of its own, so the build logs a warning for it; the output is
  still complete.

The server therefore registers one responder per version that still has live
methods (`CalculatorContractResponder`, `CalculatorContractV2Responder`, ...),
and a client uses the newest `Caller`. `example/bin/main_versioned.dart` runs
this setup end to end.

## Annotation reference

### `@RpcService`

| Parameter | Default | Meaning |
| --- | --- | --- |
| `name` | required | Service name used for routing. Must not be empty. |
| `kind` | `RpcServiceKind.unidirectional` | `unidirectional` generates Caller and Responder; `peer` generates Peer and PeerCaller. |
| `transferMode` | `RpcDataTransferMode.auto` | Default mode for every method and the default of the generated constructors. |
| `description` | `null` | Documentation of the contract. Not emitted into generated code. |
| `grpcDescriptor` | `false` | Emit a `grpcDescriptor` field on the `Names` class (see below). |

### `@RpcMethod`

| Parameter | Default | Meaning |
| --- | --- | --- |
| `name` | required | Method name used for routing. Unique within the service. |
| `kind` | required on the plain constructor | Set by the named constructors. |
| `transferMode` | service's mode | Per-method override. |
| `requestCodec`, `responseCodec` | generated | Codec `Type` with a `const` constructor. |
| `description` | `null` | Passed to the responder's `add*Method` registration. |

### `@RpcRemoved`

`@RpcRemoved([message])` on an overridden method of a versioned contract. See
[Versioning](#versioning).

## gRPC Server Reflection

With `@RpcService(grpcDescriptor: true)` the `Names` class gets a
`FileDescriptorProto` that describes the service:

```dart
class CalculatorContractNames {
  // ...
  static final grpcDescriptor = Uint8List.fromList(const [/* bytes */]);
}
```

Register it with [rpc_dart_grpc_reflection] so `grpcurl list` and
`grpcurl describe` work:

```dart
final registry = RpcReflectionRegistry()
  ..addFileDescriptor(CalculatorContractNames.grpcDescriptor);
registry.attachTo(endpoint);
```

- A dot in the service name separates the proto package from the service:
  `Calculator.v2` becomes package `Calculator`, service `v2`.
- Message fields are numbered in declaration order unless annotated with
  `@RpcProtoField(n)` from `package:rpc_dart_generator/rpc_dart_generator.dart`.
  Declaration order changes when a field is added, removed or moved, which
  changes the wire format, so the build warns about unannotated fields. A
  library that uses `@RpcProtoField` needs `rpc_dart_generator` in
  `dependencies`, not only `dev_dependencies`.

## Examples

`example/` contains a zero-copy contract with versions
(`lib/calculator_contract.dart`), a codec contract
(`lib/calculator_with_codec.dart`), and runnable programs in `bin/`.

[rpc_dart]: https://pub.dev/packages/rpc_dart
[rpc_dart_grpc_reflection]: https://pub.dev/packages/rpc_dart_grpc_reflection
