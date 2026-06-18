<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Getting Started

This guide builds a small calculator service end-to-end: define the interface, generate code, implement the server, wire both sides, make a call, and write a test.

---

## 1. Add Dependencies

```yaml
# pubspec.yaml
dependencies:
  rpc_dart: ^2.6.1

dev_dependencies:
  rpc_dart_generator: ^0.1.6
  build_runner: any
```

```sh
fvm dart pub get
```

---

## 2. Define the Service Interface

Annotate an abstract class with `@RpcService` and each method with `@RpcMethod`. The method signature determines the RPC pattern.

```dart
// lib/src/calculator_contract.dart
import 'package:rpc_dart/rpc_dart.dart';

part 'calculator_contract.g.dart';

@RpcService(name: 'Calculator', transferMode: RpcDataTransferMode.codec)
abstract class ICalculatorContract {
  @RpcMethod.unary(name: 'add')
  Future<AddResponse> add(AddRequest request, {RpcContext? context});

  @RpcMethod.serverStream(name: 'countUp')
  Stream<CountResponse> countUp(CountRequest request, {RpcContext? context});
}
```

Models must implement `IRpcSerializable` (provides `toJson()`) and have a `fromJson` factory:

```dart
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

---

## 3. Run the Generator

```sh
fvm dart run build_runner build
```

The generator reads `ICalculatorContract`, strips the leading `I`, and produces classes in `calculator_contract.g.dart`:

- `CalculatorContractResponder` — server side, extends `RpcResponderContract`
- `CalculatorContractCaller` — client side, wraps `RpcCallerEndpoint`

---

## 4. Implement the Responder

Extend the generated responder and implement the methods:

```dart
// lib/src/calculator_responder.dart
import 'package:rpc_dart/rpc_dart.dart';
import 'calculator_contract.dart';

class CalculatorResponder extends CalculatorContractResponder {
  @override
  Future<AddResponse> add(AddRequest request, {RpcContext? context}) async {
    return AddResponse(result: request.a + request.b);
  }

  @override
  Stream<CountResponse> countUp(CountRequest request, {RpcContext? context}) async* {
    for (var i = 1; i <= request.upTo; i++) {
      yield CountResponse(value: i);
    }
  }
}
```

---

## 5. Wire Up Server and Client

```dart
// bin/main.dart
import 'package:rpc_dart/rpc_dart.dart';
import '../lib/src/calculator_contract.dart';
import '../lib/src/calculator_responder.dart';

Future<void> main() async {
  // Transport pair: caller side and responder side
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

  // Server
  final server = RpcResponderEndpoint(transport: responderTransport);
  server.registerServiceContract(CalculatorResponder());
  server.start();

  // Client
  final caller = CalculatorContractCaller(
    RpcCallerEndpoint(transport: callerTransport),
  );

  // Unary call
  final response = await caller.add(AddRequest(a: 4, b: 7));
  print('4 + 7 = ${response.result}'); // 4 + 7 = 11

  // Server-streaming call
  await for (final event in caller.countUp(CountRequest(upTo: 5))) {
    print('count: ${event.value}');
  }

  await caller.endpoint.close();
  await server.close();
}
```

!!! note "Swapping transports"
    The only thing that changes when moving to production is the transport construction line.
    Replace `RpcInMemoryTransport.pair()` with a WebSocket, HTTP/2, or Isolate transport —
    the service code stays identical.

---

## 6. Write a Test

`RpcInMemoryTransport.pair()` creates a fully in-process bidirectional transport — no network, no ports, fast:

```dart
// test/calculator_test.dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';
import '../lib/src/calculator_contract.dart';
import '../lib/src/calculator_responder.dart';

void main() {
  late CalculatorContractCaller caller;
  late RpcResponderEndpoint server;

  setUp(() {
    final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

    server = RpcResponderEndpoint(transport: responderTransport);
    server.registerServiceContract(CalculatorResponder());
    server.start();

    caller = CalculatorContractCaller(
      RpcCallerEndpoint(transport: callerTransport),
    );
  });

  tearDown(() async {
    await caller.endpoint.close();
    await server.close();
  });

  test('add returns correct sum', () async {
    final response = await caller.add(AddRequest(a: 10, b: 32));
    expect(response.result, equals(42));
  });

  test('countUp emits values 1..n', () async {
    final values = await caller.countUp(CountRequest(upTo: 3)).toList();
    expect(values.map((e) => e.value).toList(), equals([1, 2, 3]));
  });
}
```

```sh
fvm dart test
```

---

## Next Steps

- [Core Framework](core/rpc_dart.md) — contracts, endpoints, context, middleware, zero-copy
- [Code Generation](core/generator.md) — annotations reference, transfer modes, build config
- [Transports](transports/index.md) — choose the right transport for your use case
- [Compression](core/compression.md) — add gzip with one line
- [OpenTelemetry](core/opentelemetry.md) — distributed tracing