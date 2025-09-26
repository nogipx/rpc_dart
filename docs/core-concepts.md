# Core concepts

RPC Dart is built around several core concepts that work together to provide a
powerful and flexible Remote Procedure Call framework. Understanding these
concepts is essential to effectively using the library.

## Key components

- **Contracts** – define the interface between services with method names and
  signatures.
- **Endpoints** – handle communication between client and server sides.
- **Transports** – manage the underlying communication mechanism (InMemory,
  HTTP, WebSocket, etc.).
- **Context** – carries metadata and control information across RPC calls.

## Contracts

Contracts in RPC Dart define the service interface—what methods are available
and how they should be called. They serve as the **single source of truth** for
both client and server implementations.

### Contract definition

```dart
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodAdd = 'add';
  static const methodSubtract = 'subtract';
  static const methodDivide = 'divide';
}
```

### Benefits

- **Type safety** – ensures consistent method signatures across client and
  server.
- **Documentation** – serves as living documentation of available services.
- **Versioning** – easy to version and evolve your API.
- **Code generation** – can be used to generate client and server stubs.

## Endpoints

Endpoints are the communication points that handle RPC calls. There are two
types:

### RpcCallerEndpoint (client)

The client-side endpoint that initiates RPC calls:

```dart
final caller = RpcCallerEndpoint(transport: transport);
final calculator = CalculatorCaller(caller);

// Make RPC call
final result = await calculator.add(AddRequest(5, 3));
```

### RpcResponderEndpoint (server)

The server-side endpoint that handles incoming RPC calls:

```dart
final responder = RpcResponderEndpoint(transport: transport);
responder.registerServiceContract(CalculatorResponder());
responder.start();
```

## Transports

Transports define **how** messages are sent between endpoints. RPC Dart is
transport-agnostic, meaning you can switch transports without changing your
business logic.

### Available transports

| Transport | Use case | Performance | Complexity |
|-----------|----------|-------------|------------|
| **InMemory** | Testing, single-process | Highest (zero-copy) | Lowest |
| **HTTP** | Web services, microservices | Medium | Medium |
| **WebSocket** | Real-time, bidirectional | Medium | Medium |
| **Isolate** | Multi-core, isolation | High | Higher |

### Transport example

```dart
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

// Development/Testing
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

// Production HTTP/2 (inside an async function)
final httpTransport = await RpcHttp2CallerTransport.secureConnect(
  host: 'api.example.com',
);

// Real-time WebSocket
final wsTransport = RpcWebSocketCallerTransport.connect(
  Uri.parse('wss://api.example.com/rpc'),
);
```

The same service code works with any transport!

## Context

RPC Context carries additional information alongside the actual RPC call data.

### What context contains

- **Correlation ID** – unique identifier for request tracing.
- **Deadline** – request timeout information.
- **Metadata** – custom key-value pairs.
- **Cancellation** – ability to cancel ongoing operations.

### Using context

```dart
// Server side - accessing context
Future<AddResponse> _add(AddRequest request, {RpcContext? context}) async {
  final correlationId = context?.correlationId;
  final userAgent = context?.getHeader('user-agent');

  if (context?.isCancelled ?? false) {
    throw RpcException('Request was cancelled');
  }

  return AddResponse(request.a + request.b);
}

// Client side - passing metadata
final context = RpcContextBuilder()
    .withHeader('user-agent', 'MyApp/1.0')
    .withTimeout(const Duration(seconds: 5))
    .build();

final result = await calculator.add(
  AddRequest(5, 3),
  context: context,
);
```

## RPC types

RPC Dart supports all standard RPC communication patterns.

### Unary RPC

Simple request-response pattern:

```dart
Future<AddResponse> add(AddRequest request) {
  return callUnary<AddRequest, AddResponse>(
    methodName: 'add',
    request: request,
  );
}
```

### Server streaming

Server sends multiple responses to a single request:

```dart
Stream<NumberResponse> getNumbers(NumberRequest request) {
  return callServerStream<NumberRequest, NumberResponse>(
    methodName: 'getNumbers',
    request: request,
  );
}
```

### Client streaming

Client sends multiple requests, server responds once:

```dart
Future<SumResponse> sumNumbers(Stream<NumberRequest> requests) {
  return callClientStream<NumberRequest, SumResponse>(
    methodName: 'sumNumbers',
    requests: requests,
  );
}
```

### Bidirectional streaming

Both client and server can send multiple messages:

```dart
Stream<EchoResponse> echo(Stream<EchoRequest> requests) {
  return callBidirectionalStream<EchoRequest, EchoResponse>(
    methodName: 'echo',
    requests: requests,
  );
}
```

## Zero-copy optimisation

One of RPC Dart's unique features is **zero-copy** object transfer with InMemory
transport:

```dart
class LargeData {
  final List<int> data = List.generate(1000000, (i) => i);
}

// With InMemory transport, this object is passed by reference
// No serialization/deserialization overhead!
final result = await service.processLargeData(LargeData());
```

### Benefits

- **Maximum performance** – no serialization overhead.
- **Memory efficient** – objects are not duplicated.
- **Type preservation** – full Dart type information maintained.

### When to use

- Single-process applications.
- High-performance computing.
- Large data transfers.
- Development and testing.

## Error handling

RPC Dart provides structured error handling.

### `RpcException`

```dart
// Server throws structured errors
if (request.b == 0) {
  throw RpcException(
    code: 'DIVISION_BY_ZERO',
    message: 'Cannot divide by zero',
    details: {'operand': 'b', 'value': 0},
  );
}

// Client catches and handles
try {
  final result = await calculator.divide(DivideRequest(10, 0));
} on RpcException catch (e) {
  print('RPC Error: ${e.code} - ${e.message}');
  print('Details: ${e.details}');
}
```

## Middleware support

RPC Dart supports middleware for cross-cutting concerns.

```dart
// Logging middleware
class LoggingMiddleware implements IRpcMiddleware {
  @override
  Future<dynamic> processRequest(
    String serviceName,
    String methodName,
    dynamic request,
  ) async {
    print('Calling ${serviceName}.${methodName}');
    return request;
  }

  @override
  Future<dynamic> processResponse(
    String serviceName,
    String methodName,
    dynamic response,
  ) async {
    print('Completed ${serviceName}.${methodName}');
    return response;
  }
}

// Register middleware (extend the endpoints if you need to invoke hooks manually)
responder.addMiddleware(LoggingMiddleware());

> **Note:** The base endpoints store middleware and expose their count through
> diagnostics. If you need a full interception pipeline today, extend the
> endpoint classes and invoke `processRequest`/`processResponse` around your
> handlers.
```

## Best practices

### Service design

1. **Keep contracts simple** – one responsibility per service.
2. **Use meaningful names** – clear method and parameter names.
3. **Version your contracts** – plan for API evolution.
4. **Handle errors gracefully** – use structured error responses.

### Performance

1. **Choose appropriate transport** – InMemory for single-process, HTTP for distributed.
2. **Use streaming** – for large datasets or real-time communication.
3. **Implement timeouts** – set reasonable deadlines for requests.
4. **Consider batching** – group related operations.

### Testing

1. **Use InMemory transport** – for fast, isolated tests.
2. **Mock services** – create test implementations of contracts.
3. **Test error scenarios** – verify error handling works correctly.
4. **Integration testing** – test with real transports.

## Next steps

Now that you understand the core concepts, explore the
[architecture](architecture.md) to see how everything fits together.
