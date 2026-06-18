<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Core Framework

The `rpc_dart` package is the foundation of the entire ecosystem. It defines the transport abstraction, contract model, endpoint lifecycle, context propagation, and the middleware/interceptor pipeline.

---

## Transport

`IRpcTransport` is the only interface a transport must implement:

```dart
abstract interface class IRpcTransport {
  Stream<RpcTransportMessage> get incomingMessages;
  bool get isClosed;
  bool get supportsZeroCopy;

  int createStream();
  Future<void> sendMessage(RpcTransportMessage message);
  Future<void> close();
  Future<RpcHealthStatus> health();
}
```

All transports are interchangeable — you can swap them without touching service code.

### InMemoryTransport

The built-in in-process transport. Used for testing and for co-located services that run in the same isolate.

```dart
final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();
```

`pair()` returns two connected transports. Messages sent to one arrive on the other. When `supportsZeroCopy` is `true` (InMemory always is), the endpoint skips serialization and passes objects directly by reference.

---

## Contracts

A contract is the typed description of one RPC service. There are two sides:

- **`RpcResponderContract`** — server side, registers handlers
- **`RpcCallerContract`** — client side, dispatches calls

### RpcResponderContract

Extend it, call `super(serviceName)`, and register handlers in `setup()`:

```dart
final class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super('Calculator');

  @override
  void setup() {
    addUnaryMethod<AddRequest, AddResponse>(
      methodName: 'add',
      handler: (request, {context}) async {
        return AddResponse(result: request.a + request.b);
      },
      requestCodec: RpcCodec<AddRequest>(AddRequest.fromJson),
      responseCodec: RpcCodec<AddResponse>(AddResponse.fromJson),
    );

    addServerStreamMethod<CountRequest, CountResponse>(
      methodName: 'countUp',
      handler: (request, {context}) async* {
        for (var i = 1; i <= request.upTo; i++) {
          yield CountResponse(value: i);
        }
      },
      requestCodec: RpcCodec<CountRequest>(CountRequest.fromJson),
      responseCodec: RpcCodec<CountResponse>(CountResponse.fromJson),
    );
  }
}
```

Available registration methods:

| Method | RPC pattern |
|---|---|
| `addUnaryMethod` | Single request → single response |
| `addServerStreamMethod` | Single request → response stream |
| `addClientStreamMethod` | Request stream → single response |
| `addBidirectionalMethod` | Request stream ↔ response stream |

### RpcCallerContract

`RpcCallerContract` wraps a `RpcCallerEndpoint` and provides typed call methods. In practice you rarely use it directly — the code generator produces a subclass for you. For manual use:

```dart
final caller = RpcCallerContract('Calculator', callerEndpoint);

final response = await caller.callUnary<AddRequest, AddResponse>(
  methodName: 'add',
  request: AddRequest(a: 2, b: 3),
  requestCodec: RpcCodec<AddRequest>(AddRequest.fromJson),
  responseCodec: RpcCodec<AddResponse>(AddResponse.fromJson),
);
```

---

## Endpoints

An endpoint manages the lifecycle of one transport connection and runs the middleware/interceptor pipeline.

### RpcResponderEndpoint

```dart
final server = RpcResponderEndpoint(transport: responderTransport);
server.registerServiceContract(CalculatorResponder());
server.start();

// later
await server.close();
```

Key methods:

| Method | Description |
|---|---|
| `registerServiceContract(contract)` | Register a responder contract |
| `unregisterServiceContract(serviceName)` | Remove a contract |
| `start()` | Begin processing incoming messages |
| `close()` | Stop and close the transport |
| `addMiddleware(mw)` | Add a middleware to the pipeline |
| `addInterceptor(interceptor)` | Add an interceptor to the pipeline |
| `health()` | Current health snapshot |

### RpcCallerEndpoint

```dart
final callerEndpoint = RpcCallerEndpoint(transport: callerTransport);

// Direct unary call (without a contract subclass)
final response = await callerEndpoint.unaryRequest<AddRequest, AddResponse>(
  serviceName: 'Calculator',
  methodName: 'add',
  request: AddRequest(a: 2, b: 3),
  requestCodec: RpcCodec<AddRequest>(AddRequest.fromJson),
  responseCodec: RpcCodec<AddResponse>(AddResponse.fromJson),
);

await callerEndpoint.close();
```

---

## Data Transfer Modes

Every method can transfer data in one of two modes:

| Mode | How it works | When to use |
|---|---|---|
| `RpcDataTransferMode.zeroCopy` | Objects passed by reference, no serialization | InMemory transport only (same process) |
| `RpcDataTransferMode.codec` | Objects serialized to CBOR via `RpcCodec` | Any transport, any platform |

`zeroCopy` is automatically active when the transport reports `supportsZeroCopy == true` and no codec is provided. Over network transports, `codec` mode is always used.

### RpcCodec

`RpcCodec<T>` is CBOR-based. The model must implement `IRpcSerializable`:

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

// Codec instance
final codec = RpcCodec<AddRequest>(AddRequest.fromJson);
```

Primitive types (`String`, `int`, `double`, `bool`, `List`) have built-in wrappers — `RpcString`, `RpcInt`, `RpcDouble`, `RpcBool`, `RpcList<T>`, `RpcNull` — so you don't need to define a model for simple payloads.

---

## Context

`RpcContext` carries metadata through the full call chain — headers, deadline, cancellation token, trace ID, and arbitrary typed values. It is immutable; every mutation returns a new instance.

```dart
// Factory constructors
final ctx = RpcContext.empty();
final ctx = RpcContext.withHeaders({'x-user-id': '42'});
final ctx = RpcContext.withTimeout(Duration(seconds: 10));
final ctx = RpcContext.withDeadline(DateTime.now().add(Duration(minutes: 1)));

// Builder (fluent)
final ctx = RpcContextBuilder()
    .withHeader('x-tenant', 'acme')
    .withTimeout(Duration(seconds: 30))
    .withBearerAuth(token)
    .build();

// Deriving from existing context
final child = ctx.createChild(); // inherits traceId, new requestId
final extended = ctx.withAdditionalHeaders({'x-extra': 'value'});
```

Reading context in a handler:

```dart
Future<Response> handle(Request req, {RpcContext? context}) async {
  final userId = context?.getHeader('x-user-id');
  final span   = context?.getValue(OtelRpcKeys.span);
  // ...
}
```

### Deadlines and Cancellation

```dart
// Deadline — expires at an absolute point in time
final ctx = RpcContext.withDeadline(DateTime.now().add(Duration(seconds: 5)));
print(ctx.isExpired);       // false
print(ctx.remainingTime);   // ~5s

// Cancellation token — cancel explicitly
final token = RpcCancellationToken();
final ctx = RpcContext.withCancellation(token); // or RpcContextBuilder().withCancellation(token)

// In a handler, check for cancellation
token.throwIfCancelled(); // throws RpcCancelledException if cancelled

// Cancel from outside
token.cancel('user logged out');
print(token.isCancelled); // true
```

When a deadline expires or a token is cancelled, the framework throws:

- `RpcDeadlineExceededException` — deadline passed
- `RpcCancelledException` — token was cancelled

---

## Middleware and Interceptors

Both are added to an endpoint and run for every call through that endpoint.

### Middleware

Transforms the request before it reaches the handler and the response before it is returned. Runs in registration order on the way in, reverse order on the way out.

```dart
class AuthMiddleware implements IRpcMiddleware {
  @override
  Future<TRequest> processRequest<TRequest>(
    RpcMiddlewareContext call,
    TRequest request,
  ) async {
    final token = call.context.getHeader('authorization');
    if (token == null) throw RpcException('unauthorized');
    return request;
  }

  @override
  Future<TResponse> processResponse<TResponse>(
    RpcMiddlewareContext call,
    TResponse response,
  ) async => response;
}

endpoint.addMiddleware(AuthMiddleware());
```

`RpcMiddlewareContext` exposes `serviceName`, `methodName`, `endpoint`, and `context`.

### Interceptors

Wrap the entire call lifecycle, including streams. Useful for tracing, logging, and metrics.

```dart
class LoggingInterceptor implements IRpcInterceptor {
  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcInterceptorContext<TRequest> ctx,
    Future<TResponse> Function() next,
  ) async {
    print('→ ${ctx.serviceName}/${ctx.methodName}');
    final response = await next();
    print('← done');
    return response;
  }

  // interceptServerStream, interceptClientStream, interceptBidirectionalStream
  // follow the same pattern with Stream<T> instead of Future<T>
}

endpoint.addInterceptor(LoggingInterceptor());
```

Interceptors are ordered as a stack: first registered wraps outermost.

---

## Health

Both endpoints expose a `health()` method returning a `RpcHealthStatus`:

```dart
final status = await endpoint.health();
print(status.isHealthy); // true
print(status.level);     // RpcHealthLevel.healthy
```

`RpcHealthLevel` values: `healthy`, `reconnecting`, `degraded`, `unhealthy`, `closed`.

The caller endpoint also supports ping:

```dart
final pong = await callerEndpoint.ping(timeout: Duration(seconds: 2));
```

---

## Errors

| Exception | When thrown |
|---|---|
| `RpcException` | Base framework exception |
| `RpcCancelledException` | Cancellation token was cancelled |
| `RpcDeadlineExceededException` | Deadline passed before response |