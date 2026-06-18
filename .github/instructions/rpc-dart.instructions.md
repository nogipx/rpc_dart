<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# RPC Dart Library AI Agent Guide

This is a **transport-agnostic RPC framework** for Dart with type-safe contracts, streaming support, and flexible architecture for building distributed applications.

## Core Architecture Patterns

### Contract-Responder-Caller Trinity
Every RPC service follows this pattern:
- **Contract Interface** - API definition with static constants
- **Responder** (`ServiceResponder extends RpcResponderContract`) - server implementation
- **Caller** (`ServiceCaller extends RpcCallerContract`) - client proxy

Example naming:
```dart
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodCalculate = 'calculate';
}
```

### Data Transfer Modes (Critical for Code Generation)
The library supports three modes via `RpcDataTransferMode`:
- **`auto`** (default) - No codecs = zero-copy, with codecs = serialization
- **`zeroCopy`** - Direct object transfer (InMemoryTransport only)
- **`codec`** - Serialization required (for network transports)

**Key Rule**: When codecs are specified in `auto` mode, BOTH `requestCodec` and `responseCodec` must be provided or neither.

### Method Registration Patterns
In Responder's `setup()`:
```dart
// Zero-copy (no codecs)
addUnaryMethod<Request, Response>(
  methodName: 'calculate',
  handler: calculate,
);

// With serialization (both codecs required)
addUnaryMethod<Request, Response>(
  methodName: 'calculate', 
  handler: calculate,
  requestCodec: Request.codec,
  responseCodec: Response.codec,
);
```

## Essential Development Workflows

### Building and Testing
Use melos scripts (one-time: `dart pub global activate melos`):
- `melos run test` - Run tests across packages
- `melos run prepare` - Pre-publish pipeline (license sync/annotate, format, analyze, reuse lint, tests)
- `melos run coverage` - Coverage for the package(s) you pick (opens HTML)
- `fvm dart pub get` (at repo root) - Resolve the whole workspace

### Project Structure Knowledge
- `lib/src/` - Core implementation organized by domain
- `example/` - Comprehensive usage examples for all 4 RPC patterns
- `test/` - Organized by feature areas (core/, endpoint/, streams/, etc.)
- Uses FVM for Dart version management

### Transport Patterns
When creating RPC connections:
```dart
// Local development/testing
final (client, server) = RpcInMemoryTransport.pair();

// Endpoints
final responder = RpcResponderEndpoint(transport: server);
final caller = RpcCallerEndpoint(transport: client);

// Always register contracts before starting
responder.registerServiceContract(ServiceResponder());
responder.start();
```

## RPC Interaction Types (All Supported)

1. **Unary** - Request → Response
2. **Server Stream** - Request → Stream<Response>  
3. **Client Stream** - Stream<Request> → Response
4. **Bidirectional** - Stream<Request> ↔ Stream<Response>

Each has corresponding `addXxxMethod` and `callXxx` methods.

## Context and Cancellation Patterns

### RpcContext Usage
```dart
// With cancellation token
final context = RpcContext.withCancellation(cancellationToken);

// With timeout
final context = RpcContext.withTimeout(Duration(seconds: 30));

// For service calls (trace inheritance)
final context = RpcContext.forServiceCall(
  parentContext: parentContext,
  fromService: 'UserService',
  toService: 'PaymentService', 
  operation: 'processPayment',
);
```

### Cancellation in Handlers
Always check cancellation in long-running operations:
```dart
Future<Response> slowOperation(Request req, {RpcContext? context}) async {
  for (int i = 0; i < iterations; i++) {
    context?.cancellationToken?.throwIfCancelled();
    // do work
  }
}
```

## Service Architecture Patterns

This library serves as an **entry point for RPC functionality**, enabling clean service boundaries:
- Use `IRpcContract` interface with static constants for API definitions
- Responders contain business logic + dependencies via other Callers
- No direct service-to-service dependencies - communicate through RPC contracts
- Cross-service calls use inherited tracing for observability

## Model Conventions

### Request/Response Models
```dart
class GetUserRequest implements IRpcSerializable {
  final String userId;
  const GetUserRequest({required this.userId});
  
  factory GetUserRequest.fromJson(Map<String, dynamic> json) => 
      GetUserRequest(userId: json['userId']);
  
  @override
  Map<String, dynamic> toJson() => {'userId': userId};
  
  static final codec = RpcCodec<GetUserRequest>(GetUserRequest.fromJson);
}
```

### Zero-Copy Models (No Serialization)
For performance-critical code with InMemoryTransport:
```dart
class FastRequest {
  final double value;
  FastRequest(this.value);
  // No IRpcSerializable needed
}
```

## Testing Patterns

### Unit Tests (Mock Callers)
```dart
class MockUserService extends Mock implements UserCaller {}
// Use any mock library
```

### Integration Tests (Real RPC)
```dart
final (client, server) = RpcInMemoryTransport.pair();
final endpoint = RpcResponderEndpoint(transport: server);
endpoint.registerServiceContract(TestService());
endpoint.start();
```

## Advanced Features to Leverage

- **Transport Router** - Route calls to different transports by service/conditions
- **Stream Distributor** - Manage server streams with broadcasting/filtering
- **Built-in Primitives** - `RpcString`, `RpcInt`, etc. with operators
- **Middleware Support** - Add middleware to endpoints for cross-cutting concerns

## Common Anti-Patterns to Avoid

❌ Mixed codec modes (one codec without the other in auto/codec mode)  
❌ Direct Responder-to-Responder dependencies (use Callers for service communication)  
❌ Forgetting cancellation checks in long operations  
❌ Using mutable models for requests/responses  
❌ Not calling `responder.start()` before making calls
