# Getting started

Welcome to **RPC Dart**! This guide walks you through installing the package and
building your first service.

## Installation

### Dart

```bash
dart pub add rpc_dart
```

### Flutter

```bash
flutter pub add rpc_dart
```

For additional transport types (HTTP, WebSocket, isolate) also add:

```bash
dart pub add rpc_dart_transports
```

## Your first RPC service

Let's create a simple calculator service to demonstrate the core concepts of RPC
Dart.

### 1. Define the contract

First, define the service contract with constants for service and method names:

```dart
// calculator_contract.dart
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodAdd = 'add';
}
```

### 2. Create request/response models

Define the data models for your RPC calls:

```dart
// models.dart
class AddRequest {
  final double a;
  final double b;

  AddRequest(this.a, this.b);
}

class AddResponse {
  final double result;

  AddResponse(this.result);
}
```

### 3. Implement the server (responder)

Create a responder that handles incoming RPC calls:

```dart
// calculator_responder.dart
import 'package:rpc_dart/rpc_dart.dart';

final class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super(ICalculatorContract.name);

  @override
  void setup() {
    // Register unary method handler
    addUnaryMethod<AddRequest, AddResponse>(
      methodName: ICalculatorContract.methodAdd,
      handler: _add,
    );
  }

  Future<AddResponse> _add(AddRequest request, {RpcContext? context}) async {
    final result = request.a + request.b;
    return AddResponse(result);
  }
}
```

### 4. Create the client (caller)

Implement a client that calls the RPC methods:

```dart
// calculator_caller.dart
import 'package:rpc_dart/rpc_dart.dart';

final class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint)
    : super(ICalculatorContract.name, endpoint);

  Future<AddResponse> add(AddRequest request) {
    return callUnary<AddRequest, AddResponse>(
      methodName: ICalculatorContract.methodAdd,
      request: request,
    );
  }
}
```

### 5. Put it all together

Now let's create a complete example that sets up the transport, endpoints, and
makes an RPC call:

```dart
// main.dart
import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  // Create InMemory transport pair
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // Setup responder endpoint
  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(CalculatorResponder());
  responder.start();

  // Setup caller endpoint
  final caller = RpcCallerEndpoint(transport: clientTransport);

  // Create calculator client
  final calculator = CalculatorCaller(caller);

  // Make RPC call
  final result = await calculator.add(AddRequest(10, 5));
  print('10 + 5 = ${result.result}'); // Output: 10 + 5 = 15.0

  // Cleanup
  await caller.close();
  await responder.close();
}
```

## Key benefits

- 🚀 **Zero-copy performance**: InMemory transport passes objects directly without
  serialization overhead.
- 🔒 **Type safety**: All RPC calls are strongly typed, catching errors at compile
  time.
- 🧪 **Easy testing**: InMemory transport makes unit and integration testing
  straightforward.
- 🔌 **Transport agnostic**: Switch transports without changing business logic.

## Next steps

- Learn the [core concepts](core-concepts.md)
- Explore the [architecture](architecture.md)
- Browse [examples on GitHub](https://github.com/nogipx/rpc_dart/tree/main/example)
- Open an [issue on GitHub](https://github.com/nogipx/rpc_dart/issues) if you
  have questions
