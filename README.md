<div align="center">
  <img src="docs/icon/logo.svg" alt="RPC Dart Logo" width="80" height="80">
  <h1>RPC Dart</h1>
  <p><strong>Pure Dart RPC library for type-safe communication between components</strong></p>
  
  <p>
    <a href="https://pub.dev/packages/rpc_dart"><img src="https://img.shields.io/pub/v/rpc_dart.svg" alt="Pub Version"></a>
    <a href="https://github.com/nogipx/rpc_dart/actions/workflows/ci.yml"><img src="https://github.com/nogipx/rpc_dart/workflows/CI/badge.svg" alt="CI"></a>
    <a href="https://coveralls.io/github/nogipx/rpc_dart?branch=main"><img src="https://coveralls.io/repos/github/nogipx/rpc_dart/badge.svg?branch=main" alt="Coverage Status"></a>
  </p>
  
  <p>
    <a href="README.md">🇺🇸 English</a> | 
    <a href="README_RU.md">🇷🇺 Русский</a>
  </p>
</div>


## Core Concepts

**RPC Dart** is built on the following key concepts:

- **Contracts** — define service APIs through interfaces and methods
- **Responder** — server side, handles incoming requests
- **Caller** — client side, sends requests  
- **Endpoint** — connection point, manages transport
- **Transport** — data transmission layer (InMemory, Isolate, HTTP)
- **Codec** — message serialization/deserialization

## Key Features

- **Full RPC pattern support** — unary calls, server streams, client streams, bidirectional streams
- **Zero-Copy InMemory transport** — object transport without serialization in single process
- **Type safety** — all requests/responses are strictly typed
- **Automatic tracing** — trace ID generated automatically, passed through RpcContext
- **No external dependencies** — pure Dart only
- **Built-in primitives** — ready wrappers for String, Int, Double, Bool, List
- **Easy testing** — with InMemory transport and mocks

## CORD

RPC Dart offers **CORD (Contract-Oriented Remote Domains)** — an architectural approach for structuring business logic through isolated domains with type-safe RPC contracts.

**📚 [Learn more](docs/en/cord.md)**

## Quick Start

**📚 [Full usage examples](example/)**

### 1. Define contract and models

```dart
// Contract with constants
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodCalculate = 'calculate';
}

// Zero-copy models — regular classes
class Request {
  final double a, b;
  final String op;
  Request(this.a, this.b, this.op);
}

class Response {
  final double result;
  Response(this.result);
}
```

### 2. Server (Responder)

```dart
final class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super(ICalculatorContract.name);

  @override
  void setup() {
    // Zero-copy method — DON'T specify codecs
    addUnaryMethod<Request, Response>(
      methodName: ICalculatorContract.methodCalculate,
      handler: calculate,
    );
  }

  Future<Response> calculate(Request req, {RpcContext? context}) async {
    final result = switch (req.op) {
      'add' => req.a + req.b,
      _ => 0.0,
    };
    return Response(result);
  }
}
```

### 3. Client (Caller)

```dart
final class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint) 
    : super(ICalculatorContract.name, endpoint);

  Future<Response> calculate(Request request) {
    return callUnary<Request, Response>(
      methodName: ICalculatorContract.methodCalculate,
      request: request,
    );
  }
}
```

### 4. Usage

```dart
void main() async {
  // Create inmemory transport
  final (client, server) = RpcInMemoryTransport.pair();
  
  // Setup endpoints
  final responder = RpcResponderEndpoint(transport: server);
  final caller = RpcCallerEndpoint(transport: client);
  
  // Register service
  responder.registerServiceContract(CalculatorResponder());
  responder.start();
  
  final calculator = CalculatorCaller(caller);
  
  // Call RPC method
  final result = await calculator.calculate(Request(10, 5, 'add'));
  print('10 + 5 = ${result.result}'); // 10 + 5 = 15.0
  
  // Cleanup
  await caller.close();
  await responder.close();
}
```

## Transports

### InMemory Transport (included in main library)
Perfect for development, testing, and monolith applications:

```dart
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
// Usage: development, unit tests, simple applications
```

#### 🚀 Zero-Copy 

For maximum performance, RPC Dart supports **zero-copy** object transfer without serialization (only for `RpcInMemoryTransport`):

```dart
// Zero-copy contract — just don't specify codecs!
addUnaryMethod<UserRequest, UserResponse>(
  methodName: 'GetUser',
  handler: (request, {context}) async {
    return UserResponse(id: request.id, name: 'User ${request.id}');
  },
  // DON'T specify codecs = automatic zero-copy
);
```

### Data Transfer Modes

RPC Dart supports three data transfer modes in contracts:

| Mode | Description | Usage |
|------|-------------|-------|
| **`zeroCopy`** | Force zero-copy, codecs ignored | Maximum performance |
| **`codec`** | Force serialization, codecs required | Universal compatibility |
| **`auto`** | **Smart choice**: no codecs → zero-copy, has codecs → serialization | Flexible development |

**`auto` mode (recommended)** automatically determines optimal transfer method:

```dart
final class SmartService extends RpcResponderContract {
  SmartService() : super('SmartService', 
    dataTransferMode: RpcDataTransferMode.auto); // ← Smart mode

  void setup() {
    // Will automatically choose zero-copy (no codecs specified)
    addUnaryMethod<FastRequest, FastResponse>(
      'fastMethod', 
      handler: fastHandler,
    );
    
    // Will automatically choose serialization (codecs specified)  
    addUnaryMethod<JsonRequest, JsonResponse>(
      'universalMethod',
      handler: universalHandler,
      requestCodec: jsonRequestCodec,   // ← Codecs specified
      responseCodec: jsonResponseCodec,
    );
  }
}
```

### Additional Transports

You can use ready-made transports from **[rpc_dart_transports](https://pub.dev/packages/rpc_dart_transports)** package or implement your own via `IRpcTransport` interface.

**Available transports:**
- **Isolate Transport** — for CPU-intensive tasks and failure isolation
- **HTTP Transport** — for microservices and distributed systems
- **WebSocket Transport** — for real-time applications

**Key advantage:** domain code remains unchanged when switching transports!

## Transport Router

**Transport Router** — smart proxy for routing RPC calls between transports using priority-based rules.

### Main Features

- **Service-based routing** — directs requests to different services on different transports
- **Conditional routing** — complex routing logic with context access
- **Rule priorities** — precise control over condition checking order
- **Automatic routing** — uses headers from `RpcCallerEndpoint`

### Usage Example

```dart
// Create transports for different services
final (userClient, userServer) = RpcInMemoryTransport.pair();
final (orderClient, orderServer) = RpcInMemoryTransport.pair();
final (paymentClient, paymentServer) = RpcInMemoryTransport.pair();

// Create router with rules
final router = RpcTransportRouterBuilder()
  .routeCall(
    calledServiceName: 'UserService',
    toTransport: userClient,
    priority: 100,
  )
  .routeCall(
    calledServiceName: 'OrderService', 
    toTransport: orderClient,
    priority: 100,
  )
  .routeWhen(
    toTransport: paymentClient,
    whenCondition: (service, method, context) => 
      service == 'PaymentService' && 
      context?.getHeader('x-payment-method') == 'premium',
    priority: 150,
    description: 'Premium payments to separate service',
  )
  .build();

// Use router as regular transport
final callerEndpoint = RpcCallerEndpoint(transport: router);
final userService = UserCaller(callerEndpoint);
final orderService = OrderCaller(callerEndpoint);

// Requests automatically routed to appropriate transports
final user = await userService.getUser(request);     // → userClient
final order = await orderService.createOrder(data); // → orderClient
```

**Use cases:** Microservice architecture, A/B testing, load balancing, service isolation.

## RPC Interaction Types

| Type | Description | Example Usage |
|------|-------------|---------------|
| **Unary Call** | Request → Response | CRUD operations, validation |
| **Server Stream** | Request → Stream of responses | Live updates, progress |
| **Client Stream** | Stream of requests → Response | Batch upload, aggregation |
| **Bidirectional Stream** | Stream ↔ Stream | Chats, real-time collaboration |

## Built-in Primitives

RPC Dart provides ready wrappers for primitive types:

```dart
// Built-in primitives with codecs
final name = RpcString('John');       // Strings
final age = RpcInt(25);              // Integers  
final height = RpcDouble(175.5);      // Doubles
final isActive = RpcBool(true);       // Booleans
final tags = RpcList<RpcString>([...]);  // Lists

// Convenient extensions
final message = 'Hello'.rpc;     // RpcString
final count = 42.rpc;            // RpcInt
final price = 19.99.rpc;         // RpcDouble
final enabled = true.rpc;        // RpcBool

// Numeric primitives support arithmetic operators
final sum = RpcInt(10) + RpcInt(20);      // RpcInt(30)
final product = RpcDouble(3.14) * RpcDouble(2.0);  // RpcDouble(6.28)

// Access value through .value property
final greeting = RpcString('Hello ') + RpcString('World'); 
print(greeting.value); // "Hello World"
```

## StreamDistributor

**StreamDistributor** — powerful manager for server streams that turns regular `StreamController` into message broker with advanced capabilities:

### Main Features

- **Broadcast publishing** — send messages to all connected clients
- **Filtered publishing** — send conditionally to specific clients  
- **Lifecycle management** — automatic stream creation/deletion
- **Automatic cleanup** — remove inactive streams by timer
- **Metrics and monitoring** — track activity and performance

### Usage Example

```dart
// Create distributor for notifications
final distributor = StreamDistributor<NotificationEvent>(
  config: StreamDistributorConfig(
    enableAutoCleanup: true,
    inactivityThreshold: Duration(minutes: 5),
  ),
);

// Create client streams for different users
final userStream1 = distributor.createClientStreamWithId('user_123');
final userStream2 = distributor.createClientStreamWithId('user_456');

// Listen to notifications
userStream1.listen((notification) {
  print('User 123 received: ${notification.message}');
});

// Send to all clients
distributor.publish(NotificationEvent(
  message: 'System notification for everyone',
  priority: Priority.normal,
));

// Send only to clients with specific IDs
distributor.publishFiltered(
  NotificationEvent(message: 'VIP notification'),
  (client) => ['user_123', 'premium_user_789'].contains(client.clientId),
);

// Get metrics
final metrics = distributor.metrics;
print('Active clients: ${metrics.currentStreams}');
print('Messages sent: ${metrics.totalMessages}');
```

**Use cases:** Perfect for implementing real-time notifications, chats, live updates and other pub/sub scenarios in server streams.

## Testing

```dart
// Unit test with mock (use any mock library)
class MockUserService extends Mock implements UserCaller {}

test('should handle user not found', () async {
  final mockUserService = MockUserService();
  when(() => mockUserService.getUser(any()))
      .thenThrow(RpcException(code: RpcStatus.NOT_FOUND));
  
  final bloc = UserBloc(mockUserService);
  
  expect(
    () => bloc.add(LoadUserEvent(id: '123')),
    emitsError(isA<UserNotFoundException>()),
  );
});

// Integration test with InMemory transport
test('full integration test', () async {
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  
  final server = RpcResponderEndpoint(transport: serverTransport);
  server.registerServiceContract(UserResponder(MockUserRepository()));
  server.start();
  
  final client = UserCaller(RpcCallerEndpoint(transport: clientTransport));
  
  final response = await client.getUser(GetUserRequest(id: '123'));
  expect(response.user.id, equals('123'));
});
```

## FAQ

<details>
<summary><strong>Is it production ready?</strong></summary>

We recommend thoroughly testing the library in your specific environment before production deployment.

</details>

<details>
<summary><strong>How to test RPC code?</strong></summary>

```dart
// Unit tests with mocks
class MockUserService extends Mock implements UserCaller {}

test('should handle user not found error', () async {
  final mockService = MockUserService();
  when(() => mockService.getUser(any()))
      .thenThrow(RpcException(code: RpcStatus.NOT_FOUND));
  
  final bloc = UserBloc(mockService);
  expect(() => bloc.loadUser('123'), throwsA(isA<UserNotFoundException>()));
});

// Integration tests with InMemory transport
test('full integration test', () async {
  final (client, server) = RpcInMemoryTransport.pair();
  final endpoint = RpcResponderEndpoint(transport: server);
  endpoint.registerServiceContract(TestService());
  endpoint.start();
  
  final caller = TestCaller(RpcCallerEndpoint(transport: client));
  final result = await caller.getData();
  expect(result.value, equals('expected'));
});
```

</details>

<details>
<summary><strong>What performance to expect?</strong></summary>

RPC Dart is optimized for real applications. In typical scenarios performance is more than sufficient:

**Practical observations:**
- InMemory transport has minimal overhead
- CBOR serialization is more efficient than JSON
- HTTP transport adds network latency
- Streaming is efficient for large data volumes

For most applications, development convenience and architectural clarity are more important than micro-optimizations.

</details>

<details>
<summary><strong>How to handle errors?</strong></summary>

RPC Dart uses gRPC statuses for unified error handling:

```dart
try {
  final result = await userService.getUser(request);
} on RpcException catch (e) {
  showError('RPC error: ${e.message}');
} on RpcDeadlineExceededException catch (e) {
  showError('Request timeout: ${e.timeout}');
} on RpcCancelledException catch (e) {
  showError('Operation cancelled: ${e.message}');
} catch (e) {
  // Handle unexpected errors
  logError('Unexpected error', error: e);
}
```

</details>

<details>
<summary><strong>How to scale RPC architecture?</strong></summary>

**CORD scaling principles:**

1. **Separate domains** — each domain should have clear responsibility
2. **Use contracts** — for type-safe communication
3. **Minimize coupling** — domains communicate only through RPC
4. **Centralize logic** — business logic in Responders
5. **Cache results** — in Callers for UI optimization

```dart
// ❌ Bad - direct dependencies
class OrderBloc {
  final UserRepository userRepo;
  final PaymentRepository paymentRepo;
  final NotificationRepository notificationRepo;
}

// ✅ Good - through RPC contracts
class OrderBloc {
  final UserCaller userService;
  final PaymentCaller paymentService;
  final NotificationCaller notificationService;
}
```

</details>

---

#### [Benchmark](https://bencher.dev/perf/rpc-dart?x_axis=version)

**Useful Links:**
- [CORD Architecture](docs/en/cord.md)
- [RPC Dart on pub.dev](https://pub.dev/packages/rpc_dart)
- [Source code on GitHub](https://github.com/nogipx/rpc_dart)
- [Code examples](example/)
- [Issues and support](https://github.com/nogipx/rpc_dart/issues)

*Build scalable Flutter applications with RPC Dart!* 