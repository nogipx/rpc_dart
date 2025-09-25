# InMemory transport

The **InMemory transport** is RPC Dart's highest performance transport, designed
for communication within a single process. It provides **zero-copy** object
transfer, making it ideal for high-throughput applications, testing, and
scenarios where maximum performance is required.

## Overview

- **Zero-copy performance** – objects are passed by reference without
  serialization overhead, providing maximum throughput for large data transfers.
- **Type safety** – full Dart type information is preserved across RPC
  boundaries, maintaining compile-time guarantees.
- **Perfect for testing** – ideal for unit and integration tests where you need
  fast, predictable communication.
- **Memory efficient** – no data duplication or serialization means minimal
  memory footprint.

## Zero-copy object transfer

```dart
class LargeDataSet {
  final List<ComplexObject> items = List.generate(
    100000,
    (i) => ComplexObject(id: i, data: List.filled(1000, i)),
  );
}

// With InMemory transport, this entire object is passed by reference
// No serialization, no copying, just a direct reference transfer!
final result = await service.processLargeDataSet(LargeDataSet());
```

## Type preservation

Unlike network transports that require serialization, InMemory transport
preserves full Dart type information:

```dart
// Complex types work seamlessly
class User {
  final String id;
  final DateTime createdAt;
  final Set<String> permissions;
  final Map<String, dynamic> metadata;

  User({
    required this.id,
    required this.createdAt,
    required this.permissions,
    required this.metadata,
  });
}

// Types are preserved exactly as they are
final user = await userService.getUser('123');
// user is exactly User type, not a Map or reconstructed object
```

## Usage

### Creating transport pairs

InMemory transport works with transport pairs—a connected client and server
transport:

```dart
// Create a pair of connected transports
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

// Setup server endpoint
final responder = RpcResponderEndpoint(transport: serverTransport);
responder.registerServiceContract(CalculatorResponder());
responder.start();

// Setup client endpoint
final caller = RpcCallerEndpoint(transport: clientTransport);
final calculator = CalculatorCaller(caller);

// Make RPC calls
final result = await calculator.add(AddRequest(10, 5));
print('Result: ${result.result}'); // Result: 15
```

### Complete example

#### Contract

```dart
// calculator_contract.dart
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodAdd = 'add';
  static const methodSubtract = 'subtract';
  static const methodMultiply = 'multiply';
  static const methodDivide = 'divide';
}

class MathRequest {
  final double a;
  final double b;

  MathRequest(this.a, this.b);
}

class MathResponse {
  final double result;

  MathResponse(this.result);
}
```

#### Responder

```dart
// calculator_responder.dart
import 'package:rpc_dart/rpc_dart.dart';

class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super(ICalculatorContract.name);

  @override
  void setup() {
    addUnaryMethod<MathRequest, MathResponse>(
      methodName: ICalculatorContract.methodAdd,
      handler: _add,
    );

    addUnaryMethod<MathRequest, MathResponse>(
      methodName: ICalculatorContract.methodSubtract,
      handler: _subtract,
    );

    addUnaryMethod<MathRequest, MathResponse>(
      methodName: ICalculatorContract.methodMultiply,
      handler: _multiply,
    );

    addUnaryMethod<MathRequest, MathResponse>(
      methodName: ICalculatorContract.methodDivide,
      handler: _divide,
    );
  }

  Future<MathResponse> _add(MathRequest request, {RpcContext? context}) async {
    return MathResponse(request.a + request.b);
  }

  Future<MathResponse> _subtract(MathRequest request, {RpcContext? context}) async {
    return MathResponse(request.a - request.b);
  }

  Future<MathResponse> _multiply(MathRequest request, {RpcContext? context}) async {
    return MathResponse(request.a * request.b);
  }

  Future<MathResponse> _divide(MathRequest request, {RpcContext? context}) async {
    if (request.b == 0) {
      throw RpcException(
        code: 'DIVISION_BY_ZERO',
        message: 'Cannot divide by zero',
        details: {'operand': 'b', 'value': request.b},
      );
    }
    return MathResponse(request.a / request.b);
  }
}
```

#### Caller

```dart
// calculator_caller.dart
import 'package:rpc_dart/rpc_dart.dart';

class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint)
    : super(ICalculatorContract.name, endpoint);

  Future<MathResponse> add(MathRequest request) {
    return callUnary<MathRequest, MathResponse>(
      methodName: ICalculatorContract.methodAdd,
      request: request,
    );
  }

  Future<MathResponse> subtract(MathRequest request) {
    return callUnary<MathRequest, MathResponse>(
      methodName: ICalculatorContract.methodSubtract,
      request: request,
    );
  }

  Future<MathResponse> multiply(MathRequest request) {
    return callUnary<MathRequest, MathResponse>(
      methodName: ICalculatorContract.methodMultiply,
      request: request,
    );
  }

  Future<MathResponse> divide(MathRequest request) {
    return callUnary<MathRequest, MathResponse>(
      methodName: ICalculatorContract.methodDivide,
      request: request,
    );
  }
}
```

#### Main

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
  final calculator = CalculatorCaller(caller);

  try {
    // Perform calculations
    final sum = await calculator.add(MathRequest(10, 5));
    print('10 + 5 = ${sum.result}');

    final difference = await calculator.subtract(MathRequest(10, 3));
    print('10 - 3 = ${difference.result}');

    final product = await calculator.multiply(MathRequest(4, 6));
    print('4 * 6 = ${product.result}');

    final quotient = await calculator.divide(MathRequest(15, 3));
    print('15 / 3 = ${quotient.result}');

    // Test error handling
    try {
      await calculator.divide(MathRequest(10, 0));
    } on RpcException catch (e) {
      print('Error: ${e.code} - ${e.message}');
    }
  } finally {
    await caller.close();
    await responder.close();
  }
}
```

## Use cases

### High-performance applications

```dart
class DataProcessor {
  Future<ProcessedData> processLargeDataset(LargeDataset data) async {
    // With InMemory transport, the entire dataset is passed by reference
    // No serialization overhead for millions of records
    return ProcessedData(
      results: data.records.map((record) => processRecord(record)).toList(),
    );
  }
}
```

### Testing and development

```dart
void main() {
  group('Calculator Service Tests', () {
    late RpcResponderEndpoint responder;
    late RpcCallerEndpoint caller;
    late CalculatorCaller calculator;

    setUp(() async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      responder = RpcResponderEndpoint(transport: serverTransport);
      responder.registerServiceContract(CalculatorResponder());
      responder.start();

      caller = RpcCallerEndpoint(transport: clientTransport);
      calculator = CalculatorCaller(caller);
    });

    tearDown(() async {
      await caller.close();
      await responder.close();
    });

    test('should add numbers correctly', () async {
      final result = await calculator.add(MathRequest(2, 3));
      expect(result.result, equals(5));
    });

    test('should handle division by zero', () async {
      expect(
        () => calculator.divide(MathRequest(10, 0)),
        throwsA(isA<RpcException>()),
      );
    });
  });
}
```

### Monolithic applications

```dart
void main() async {
  // Create transport pairs for different services
  final (userClientTransport, userServerTransport) = RpcInMemoryTransport.pair();
  final (orderClientTransport, orderServerTransport) = RpcInMemoryTransport.pair();
  final (paymentClientTransport, paymentServerTransport) = RpcInMemoryTransport.pair();

  // Setup all service responders
  final userResponder = RpcResponderEndpoint(transport: userServerTransport);
  userResponder.registerServiceContract(UserServiceResponder());

  final orderResponder = RpcResponderEndpoint(transport: orderServerTransport);
  orderResponder.registerServiceContract(OrderServiceResponder(
    userService: UserServiceCaller(RpcCallerEndpoint(transport: userClientTransport)),
    paymentService: PaymentServiceCaller(RpcCallerEndpoint(transport: paymentClientTransport)),
  ));

  final paymentResponder = RpcResponderEndpoint(transport: paymentServerTransport);
  paymentResponder.registerServiceContract(PaymentServiceResponder());

  await Future.wait([
    userResponder.start(),
    orderResponder.start(),
    paymentResponder.start(),
  ]);
}
```

## Streaming support

### Server streaming

```dart
// Responder
Stream<NumberData> getNumbers(NumberRequest request, {RpcContext? context}) async* {
  for (int i = 1; i <= request.count; i++) {
    yield NumberData(
      value: i,
      metadata: {'generated_at': DateTime.now()},
      complexData: generateComplexData(i),
    );
    await Future.delayed(const Duration(milliseconds: 100));
  }
}

// Caller
Stream<NumberData> getNumbers(NumberRequest request) {
  return callServerStream<NumberRequest, NumberData>(
    methodName: 'getNumbers',
    request: request,
  );
}

// Usage
await for (final numberData in calculator.getNumbers(NumberRequest(count: 10))) {
  print('Number: ${numberData.value}, Complex: ${numberData.complexData}');
}
```

### Client streaming

```dart
// Responder
Future<SumResult> sumNumbers(Stream<NumberData> numbers, {RpcContext? context}) async {
  double sum = 0;
  int count = 0;

  await for (final numberData in numbers) {
    sum += numberData.value;
    count++;
  }

  return SumResult(total: sum, count: count);
}

// Caller
Future<SumResult> sumNumbers(Stream<NumberData> numbers) {
  return callClientStream<NumberData, SumResult>(
    methodName: 'sumNumbers',
    requests: numbers,
  );
}
```

### Bidirectional streaming

```dart
// Responder
Stream<ProcessedData> processStream(Stream<RawData> input, {RpcContext? context}) async* {
  await for (final rawData in input) {
    final processed = ProcessedData(
      id: rawData.id,
      processedAt: DateTime.now(),
      result: processComplexData(rawData),
    );
    yield processed;
  }
}

// Caller
Stream<ProcessedData> processStream(Stream<RawData> input) {
  return callBidirectionalStream<RawData, ProcessedData>(
    methodName: 'processStream',
    requests: input,
  );
}
```

## Performance characteristics

### Benchmark results

| Operation | InMemory | HTTP | WebSocket |
|-----------|----------|------|-----------|
| Simple RPC | ~0.01ms | ~5-10ms | ~2-5ms |
| Large object (1MB) | ~0.01ms | ~50-100ms | ~20-40ms |
| Streaming (1000 items) | ~5ms | ~1-2s | ~0.5-1s |

### Memory usage

```dart
class LargeData {
  final List<ComplexObject> items = List.generate(10000, (i) => ComplexObject(i));
}

// InMemory transport: ~0 additional memory (reference passing)
// Network transports: ~2x memory usage (original + serialized copy)
```

## Limitations

### Single process only

```dart
// ✅ This works - same process
final (client, server) = RpcInMemoryTransport.pair();

// ❌ This doesn't work - different processes
// Cannot share InMemory transport across process boundaries
```

### No network communication

```dart
// ❌ Cannot use InMemory for microservices
// Use HTTP, WebSocket, or other network transports instead

// ✅ Use for monolithic applications
final (userClient, userServer) = RpcInMemoryTransport.pair();
final (orderClient, orderServer) = RpcInMemoryTransport.pair();
```

### Object lifetime considerations

```dart
class MutableData {
  List<String> items = [];
}

// ⚠️ Be careful with mutable objects
final data = MutableData();
data.items.add('initial');

final result = await service.processData(data);

// The original object might be modified by the service
```

## Best practices

### Use for development and testing

```dart
void main() {
  group('Service Tests', () {
    late ServiceCaller service;

    setUp(() async {
      final (client, server) = RpcInMemoryTransport.pair();
      // Setup endpoints...
      service = ServiceCaller(caller);
    });

    test('fast and reliable tests', () async {
      final result = await service.performOperation(data);
      expect(result, meets(criteria));
    });
  });
}
```

### Use for high-performance scenarios

```dart
class ImageProcessor {
  Future<ProcessedImage> processImage(RawImageData data) async {
    // Large image data passed by reference - no copying overhead
    return ProcessedImage(
      processed: applyFilters(data),
      metadata: generateMetadata(data),
    );
  }
}
```

### Combine with other transports

```dart
class HybridApplication {
  Future<void> setup() async {
    // Internal high-performance communication
    final (cacheClient, cacheServer) = RpcInMemoryTransport.pair();
    setupCacheService(cacheServer);

    // External API communication over HTTP/2
    final httpTransport = await RpcHttp2CallerTransport.secureConnect(
      host: 'api.external.com',
    );
    setupExternalApiClient(httpTransport);
  }
}
```

### Handle errors gracefully

```dart
try {
  final result = await service.processData(data);
  return result;
} on RpcException catch (e) {
  logger.error('RPC Error: ${e.code} - ${e.message}');
  return defaultResult;
} catch (e) {
  logger.error('Unexpected error: $e');
  rethrow;
}
```

## Migration guide

### From direct method calls

```dart
// Before: Direct method calls
class Calculator {
  double add(double a, double b) => a + b;
}

final calc = Calculator();
final result = calc.add(10, 5);

// After: RPC with InMemory transport
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodAdd = 'add';
}

final (client, server) = RpcInMemoryTransport.pair();
// ... setup endpoints ...

final result = await calculator.add(MathRequest(10, 5));
```

### To network transports

```dart
// Development with InMemory
final (client, server) = RpcInMemoryTransport.pair();

// Production with HTTP/2
final httpTransport = await RpcHttp2CallerTransport.secureConnect(
  host: 'api.production.com',
);

// Same service code works with both!
final calculator = CalculatorCaller(RpcCallerEndpoint(transport: httpTransport));
```

The InMemory transport is the perfect choice when you need maximum performance
within a single process, whether for testing, development, or high-performance
monolithic applications. Its zero-copy nature makes it unmatched for scenarios
where serialization overhead would be a bottleneck.
