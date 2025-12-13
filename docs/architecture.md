# Architecture

RPC Dart follows a layered architecture that separates concerns and provides
flexibility in how components communicate. Understanding this architecture helps
you build better applications and choose the right transport and service design
patterns.

## Architecture overview

RPC Dart's architecture consists of several layers, each with specific
responsibilities:

- **Application layer** – your business logic and service implementations that
  use RPC contracts.
- **RPC layer** – contracts, callers, responders, and routing logic.
- **Transport layer** – network communication, serialization, and message
  delivery.
- **Core layer** – base classes, utilities, and framework fundamentals.

```
┌─────────────────────────────────────────┐
│           Application Layer             │
│   ┌─────────────┐   ┌─────────────┐    │
│   │   Service   │   │   Client    │    │
│   │     A       │   │ Application │    │
│   └─────────────┘   └─────────────┘    │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│             RPC Layer                   │
│   ┌─────────────┐   ┌─────────────┐    │
│   │ Responder   │   │   Caller    │    │
│   │ Endpoint    │   │ Endpoint    │    │
│   └─────────────┘   └─────────────┘    │
│   ┌─────────────────────────────────┐   │
│   │         Contracts               │   │
│   └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│           Transport Layer               │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐  │
│   │InMemory │ │  HTTP   │ │WebSocket│  │
│   └─────────┘ └─────────┘ └─────────┘  │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│             Core Layer                  │
│   ┌─────────────────────────────────┐   │
│   │    Base Classes & Utilities     │   │
│   └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

## Core components

### 1. Contracts

Contracts define the interface between services. They specify:

- Service names and method names.
- Request and response types.
- Supported RPC patterns (unary, streaming).

```dart
abstract interface class IUserServiceContract {
  static const name = 'UserService';
  static const methodGetUser = 'getUser';
  static const methodUpdateUser = 'updateUser';
  static const methodStreamNotifications = 'streamNotifications';
}
```

### 2. Endpoints

#### `RpcResponderEndpoint`

Handles incoming RPC requests:

```dart
final responder = RpcResponderEndpoint(transport: serverTransport);

// Register service implementations
responder.registerServiceContract(UserServiceResponder());
responder.registerServiceContract(PaymentServiceResponder());

// Start handling requests
responder.start();
```

#### `RpcCallerEndpoint`

Initiates RPC calls to remote services:

```dart
final caller = RpcCallerEndpoint(transport: clientTransport);

// Create service clients
final userService = UserServiceCaller(caller);
final paymentService = PaymentServiceCaller(caller);

// Make RPC calls
final user = await userService.getUser(userId);
```

### 3. Transport abstraction

The transport layer handles message delivery between endpoints:

```dart
abstract class IRpcTransport {
  bool get isClient;
  bool get supportsZeroCopy;
  int createStream();
  Future<void> sendMetadata(int streamId, RpcMetadata metadata, {bool endStream = false});
  Future<void> sendMessage(int streamId, Uint8List data, {bool endStream = false});
  Future<void> sendDirectObject(int streamId, Object object, {bool endStream = false});
  Stream<RpcTransportMessage> get incomingMessages;
  Future<void> finishSending(int streamId);
  Future<void> close();
  Future<RpcHealthStatus> health();
  Future<RpcHealthStatus> reconnect();
}
```

This matches the production interface exposed by RPC Dart and lets you swap
transports without rewriting callers or responders.

## Design patterns

### 1. Contract pattern

Services are defined using contracts that specify the interface:

```dart
// Contract definition
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodAdd = 'add';
  static const methodSubtract = 'subtract';
}

// Responder implementation
class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super(ICalculatorContract.name);

  @override
  void setup() {
    addUnaryMethod<AddRequest, AddResponse>(
      methodName: ICalculatorContract.methodAdd,
      handler: _add,
    );
  }

  Future<AddResponse> _add(AddRequest request, {RpcContext? context}) async {
    return AddResponse(request.a + request.b);
  }
}

// Caller implementation
class CalculatorCaller extends RpcCallerContract {
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

### 2. Transport router pattern

For complex applications, you can route different services through different
transports:

```dart
final router = RpcTransportRouterBuilder.client()
    .routeCall(calledServiceName: 'UserService', toTransport: httpTransport)
    .routeCall(
      calledServiceName: 'NotificationService',
      toTransport: webSocketTransport,
    )
    .routeCall(
      calledServiceName: 'CacheService',
      toTransport: inMemoryTransport,
    )
    .build();

final caller = RpcCallerEndpoint(transport: router);
```

### 3. Middleware pattern

Implement cross-cutting concerns using middleware:

```dart
class LoggingMiddleware implements IRpcMiddleware {
  @override
  Future<dynamic> processRequest(
    String serviceName,
    String methodName,
    dynamic request,
  ) async {
    log('Calling ${serviceName}.${methodName}');
    return request;
  }

  @override
  Future<dynamic> processResponse(
    String serviceName,
    String methodName,
    dynamic response,
  ) async {
    log('Completed ${serviceName}.${methodName}');
    return response;
  }
}

// Register middleware (extend the endpoints to invoke hooks around handlers)
responder.addMiddleware(LoggingMiddleware());
```

## Message flow

### 1. Unary call flow

```
Client                    Transport                    Server
  │                          │                          │
  │ 1. callUnary()           │                          │
  ├─────────────────────────▶│                          │
  │                          │ 2. RpcMessage            │
  │                          ├─────────────────────────▶│
  │                          │                          │ 3. processRequest()
  │                          │                          ├──────────────┐
  │                          │                          │              │
  │                          │                          │◀─────────────┘
  │                          │ 4. RpcMessage            │
  │                          │◀─────────────────────────┤
  │ 5. Response              │                          │
  │◀─────────────────────────┤                          │
```

### 2. Streaming flow

```
Client                    Transport                    Server
  │                          │                          │
  │ 1. callServerStream()    │                          │
  ├─────────────────────────▶│                          │
  │                          │ 2. RpcMessage            │
  │                          ├─────────────────────────▶│
  │                          │                          │ 3. processStreamRequest()
  │                          │                          ├──────────────┐
  │                          │ 4. Stream messages       │              │
  │                          │◀─────────────────────────┤              │
  │ 5. Stream<Response>      │                          │              │
  │◀─────────────────────────┤                          │              │
  │                          │                          │◀─────────────┘
```

## Error handling architecture

RPC Dart implements a structured error handling system.

### 1. Exception hierarchy

```dart
abstract class RpcException implements Exception {
  final String code;
  final String message;
  final Map<String, dynamic>? details;
}

class RpcTimeoutException extends RpcException {
  RpcTimeoutException(String message, Duration timeout);
}

class RpcCancelledException extends RpcException {
  RpcCancelledException(String message);
}

class RpcTransportException extends RpcException {
  RpcTransportException(String message, Exception cause);
}
```

### 2. Error propagation

Errors are automatically serialized and propagated across transport boundaries:

```dart
// Server side
Future<UserResponse> getUser(UserRequest request) async {
  if (request.userId.isEmpty) {
    throw RpcException(
      code: 'INVALID_USER_ID',
      message: 'User ID cannot be empty',
      details: {'field': 'userId'},
    );
  }
  // ... implementation
}

// Client side
try {
  final user = await userService.getUser(UserRequest(userId: ''));
} on RpcException catch (e) {
  // Handle structured RPC errors
  print('Error: ${e.code} - ${e.message}');
  if (e.details != null) {
    print('Field error: ${e.details!['field']}');
  }
}
```

## Performance considerations

### 1. Zero-copy with InMemory transport

For single-process applications, InMemory transport provides maximum
performance:

```dart
class LargeDataService extends RpcResponderContract {
  @override
  void setup() {
    addUnaryMethod<LargeData, ProcessedData>(
      methodName: 'processLargeData',
      handler: _processLargeData,
    );
  }

  Future<ProcessedData> _processLargeData(LargeData data) async {
    // Direct object access - no serialization overhead
    return ProcessedData(data.processDirectly());
  }
}
```

### 2. Serialization with network transports

Network transports automatically handle serialization:

```dart
// Provide codecs when you register methods for network transports
addUnaryMethod<MyRequest, MyResponse>(
  methodName: 'Process',
  handler: _process,
  requestCodec: RpcCodec(MyRequest.fromJson),
  responseCodec: RpcCodec(MyResponse.fromJson),
);
```

### 3. Connection management

`RpcHttp2CallerTransport` keeps a single multiplexed HTTP/2 connection alive and
exposes health/reconnect hooks:

```dart
final httpTransport = await RpcHttp2CallerTransport.secureConnect(
  host: 'api.example.com',
);

final status = await httpTransport.health();
if (!status.isHealthy) {
  await httpTransport.reconnect();
}
```

## Scalability patterns

### 1. Service decomposition

Break large applications into focused services:

```dart
// User management service
abstract interface class IUserServiceContract {
  static const name = 'UserService';
  // User CRUD operations
}

// Payment processing service
abstract interface class IPaymentServiceContract {
  static const name = 'PaymentService';
  // Payment operations
}

// Notification service
abstract interface class INotificationServiceContract {
  static const name = 'NotificationService';
  // Real-time notifications
}
```

### 2. Transport selection by service

Use appropriate transports for different service types (for example
`httpTransport` from `RpcHttp2CallerTransport.secureConnect` and
`webSocketTransport` from `RpcWebSocketCallerTransport.connect`):

```dart
// Real-time services use WebSocket
final notificationService = NotificationServiceCaller(
  RpcCallerEndpoint(transport: webSocketTransport)
);

// CRUD services use HTTP
final userService = UserServiceCaller(
  RpcCallerEndpoint(transport: httpTransport)
);

// Internal cache uses InMemory
final cacheService = CacheServiceCaller(
  RpcCallerEndpoint(transport: inMemoryTransport)
);
```

### 3. Load balancing

Use multiple transports together with `RpcTransportRouter` or build a custom
transport by implementing `IRpcTransport`. You can rotate between several
`RpcHttp2CallerTransport` instances or route based on metadata such as tenant ID
and latency.

## Testing architecture

RPC Dart's architecture makes testing straightforward.

### 1. Mock services

```dart
class MockUserService extends RpcResponderContract {
  MockUserService() : super(IUserServiceContract.name);

  @override
  void setup() {
    addUnaryMethod<GetUserRequest, UserResponse>(
      methodName: IUserServiceContract.methodGetUser,
      handler: _getMockUser,
    );
  }

  Future<UserResponse> _getMockUser(GetUserRequest request) async {
    return UserResponse(
      user: User(id: request.userId, name: 'Test User'),
    );
  }
}
```

### 2. Integration testing

```dart
void main() {
  group('UserService Integration', () {
    late RpcResponderEndpoint responder;
    late RpcCallerEndpoint caller;

    setUp(() async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      responder = RpcResponderEndpoint(transport: serverTransport);
      responder.registerServiceContract(MockUserService());
      responder.start();

      caller = RpcCallerEndpoint(transport: clientTransport);
    });

    tearDown(() async {
      await caller.close();
      await responder.close();
    });

    test('should get user successfully', () async {
      final userService = UserServiceCaller(caller);
      final response = await userService.getUser(GetUserRequest(userId: '123'));

      expect(response.user.id, equals('123'));
      expect(response.user.name, equals('Test User'));
    });
  });
}
```

## Best practices

### 1. Service design

- **Single responsibility** – each service should have one clear purpose.
- **Interface segregation** – keep contracts focused and minimal.
- **Dependency inversion** – depend on contracts, not implementations.

### 2. Error handling

- **Structured errors** – use `RpcException` with codes and details.
- **Graceful degradation** – handle errors at appropriate levels.
- **Circuit breaker** – implement timeouts and retries.

### 3. Performance

- **Transport selection** – choose the right transport for each use case.
- **Streaming** – use streaming for large datasets and real-time updates.
- **Caching** – implement caching where appropriate.

### 4. Testing

- **Unit tests** – test contracts and implementations separately.
- **Integration tests** – test with real transports.
- **Mock services** – use InMemory transport for fast, isolated tests.

The architecture of RPC Dart provides flexibility, performance, and
maintainability while keeping the complexity manageable. By understanding these
patterns and principles, you can build robust, scalable applications that are
easy to test and maintain.
