# Code Generation

The `rpc_dart_generator` package eliminates boilerplate. You define an annotated abstract interface; `build_runner` generates the caller and responder implementations.

---

## Setup

```yaml
# pubspec.yaml
dev_dependencies:
  rpc_dart_generator: ^0.1.6
  build_runner: any
```

The source file must declare a `part` directive pointing to the generated file:

```dart
part 'my_contract.g.dart';
```

Run generation:

```sh
fvm dart run build_runner build
# or watch mode
fvm dart run build_runner watch
```

---

## Annotations

### @RpcService

Marks an abstract class as an RPC service contract:

```dart
@RpcService(
  name: 'Calculator',
  transferMode: RpcDataTransferMode.zeroCopy, // default
)
abstract class ICalculatorContract { ... }
```

| Parameter | Type | Description |
|---|---|---|
| `name` | `String` | Service identifier used for routing |
| `transferMode` | `RpcDataTransferMode` | Default transfer mode for all methods |

### @RpcMethod

Annotates each method. There are shorthand constructors for every pattern:

```dart
@RpcMethod.unary(name: 'add')
Future<AddResponse> add(AddRequest request, {RpcContext? context});

@RpcMethod.serverStream(name: 'countUp')
Stream<CountResponse> countUp(CountRequest request, {RpcContext? context});

@RpcMethod.clientStream(name: 'upload')
Future<UploadResponse> upload(Stream<Chunk> chunks, {RpcContext? context});

@RpcMethod.bidirectionalStream(name: 'chat')
Stream<Message> chat(Stream<Message> incoming, {RpcContext? context});
```

Or use the base constructor with an explicit `kind`:

```dart
@RpcMethod(
  name: 'countUp',
  kind: RpcMethodKind.serverStream,
  transferMode: RpcDataTransferMode.codec, // override service default
  description: 'Streams integers from 1 to n',
)
Stream<CountResponse> countUp(CountRequest request, {RpcContext? context});
```

| Parameter | Type | Description |
|---|---|---|
| `name` | `String` | Method identifier used for routing |
| `kind` | `RpcMethodKind` | `unary`, `serverStream`, `clientStream`, `bidirectionalStream` |
| `transferMode` | `RpcDataTransferMode?` | Overrides service-level default |
| `description` | `String?` | Passed to the generated `addXxxMethod` call |

---

## Transfer Modes

| Mode | Requires codec | Use case |
|---|---|---|
| `RpcDataTransferMode.zeroCopy` | No | InMemory transport, same process |
| `RpcDataTransferMode.codec` | Yes (`IRpcSerializable` + `fromJson`) | Any network transport |

In **zero-copy** mode the generator emits no codec references — objects are passed by reference through the transport.

In **codec** mode the generator emits a `XxxContractCodecs` class with `const` codec instances and wires them into every `addXxxMethod` / `callXxx` call automatically.

---

## What Gets Generated

For `ICalculatorContract` the generator produces three classes in `calculator_contract.g.dart`:

### XxxContractNames

Compile-time constants for service and method names. Use them instead of raw strings to avoid typos:

```dart
class CalculatorContractNames {
  static const service = 'Calculator';
  static const sum     = 'sum';
  static const numbers = 'numbers';

  // For running multiple instances of the same service:
  static String instance(String suffix) => '${service}_$suffix';
}
```

### XxxContractCodecs *(codec mode only)*

`const` codec instances, one per request/response type:

```dart
class CalculatorSerializeContractCodecs {
  static const codecSumRequest  = RpcCodec<SumRequest>.withDecoder(SumRequest.fromJson);
  static const codecSumResponse = RpcCodec<SumResponse>.withDecoder(SumResponse.fromJson);
}
```

### XxxContractResponder

An **abstract** class extending `RpcResponderContract`. Implements `setup()` — you only implement the methods:

```dart
// Generated (abstract)
abstract class CalculatorContractResponder extends RpcResponderContract
    implements ICalculatorContract {
  CalculatorContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  });

  @override
  void setup() {
    addUnaryMethod<SumRequest, SumResponse>(
      methodName: CalculatorContractNames.sum,
      handler: sum,
    );
    // ...
  }
}

// Your code
class CalculatorResponder extends CalculatorContractResponder {
  @override
  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) async {
    final total = request.values.fold<double>(0, (a, b) => a + b);
    return SumResponse(result: total);
  }
}
```

### XxxContractCaller

A **concrete** class extending `RpcCallerContract`. Ready to use:

```dart
// Generated (concrete, use directly)
class CalculatorContractCaller extends RpcCallerContract
    implements ICalculatorContract {
  CalculatorContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.zeroCopy,
  });
}

// Usage
final caller = CalculatorContractCaller(
  RpcCallerEndpoint(transport: callerTransport),
);
final result = await caller.sum(SumRequest(values: [1, 2, 3]));
```

---

## Multiple Service Instances

If you need to run two instances of the same service (e.g. a primary and a beta), use `serviceNameOverride` and `XxxContractNames.instance(suffix)`:

```dart
server.registerServiceContract(CalculatorResponder());
server.registerServiceContract(
  CalculatorResponder(
    serviceNameOverride: CalculatorContractNames.instance('beta'),
  ),
);

final callerBeta = CalculatorContractCaller(
  endpoint,
  serviceNameOverride: CalculatorContractNames.instance('beta'),
);
```

---

## Models for Codec Mode

When using `RpcDataTransferMode.codec`, models must implement `IRpcSerializable` and provide a `fromJson` factory. The generator uses `fromJson` to construct codec instances at compile time (`const` constructors required).

```dart
class SumRequest implements IRpcSerializable {
  SumRequest({required this.values});
  final List<double> values;

  factory SumRequest.fromJson(Map<String, dynamic> json) {
    final raw = json['values'] as List<dynamic>? ?? const [];
    return SumRequest(values: raw.map((e) => (e as num).toDouble()).toList());
  }

  @override
  Map<String, dynamic> toJson() => {'values': values};
}
```

You can also use `json_serializable` — the generator only requires that `fromJson` and `toJson` exist.

---

## Full Example

=== "Zero-copy (same process)"

    ```dart
    // contract.dart
    import 'package:rpc_dart/rpc_dart.dart';
    part 'contract.g.dart';

    @RpcService(name: 'Calculator', transferMode: RpcDataTransferMode.zeroCopy)
    abstract class ICalculatorContract {
      @RpcMethod.unary(name: 'sum')
      Future<SumResponse> sum(SumRequest request, {RpcContext? context});

      @RpcMethod.serverStream(name: 'numbers')
      Stream<SumResponse> numbers(SumRequest request, {RpcContext? context});
    }

    class SumRequest  { SumRequest({required this.values}); final List<double> values; }
    class SumResponse { SumResponse({required this.result}); final double result; }
    ```

=== "Codec (network transports)"

    ```dart
    // contract.dart
    import 'package:rpc_dart/rpc_dart.dart';
    part 'contract.g.dart';

    @RpcService(name: 'Calculator', transferMode: RpcDataTransferMode.codec)
    abstract class ICalculatorContract {
      @RpcMethod.unary(name: 'sum')
      Future<SumResponse> sum(SumRequest request, {RpcContext? context});
    }

    class SumRequest implements IRpcSerializable {
      SumRequest({required this.values});
      final List<double> values;
      factory SumRequest.fromJson(Map<String, dynamic> json) =>
          SumRequest(values: (json['values'] as List).map((e) => (e as num).toDouble()).toList());
      @override
      Map<String, dynamic> toJson() => {'values': values};
    }

    class SumResponse implements IRpcSerializable {
      SumResponse({required this.result});
      final double result;
      factory SumResponse.fromJson(Map<String, dynamic> json) =>
          SumResponse(result: (json['result'] as num).toDouble());
      @override
      Map<String, dynamic> toJson() => {'result': result};
    }
    ```