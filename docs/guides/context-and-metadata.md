# Context, metadata & deadlines

`RpcContext` is the **metadata envelope** that travels with every call. It stores
headers, deadlines, cancellation tokens, trace identifiers, and arbitrary
key/value pairs so that both caller and responder can collaborate without
sprinkling optional parameters everywhere.

## Core building blocks

- **Headers** – typed access to key/value pairs that end up as HTTP/2 metadata
  headers.
- **Deadlines** – absolute or relative timeouts propagated across services.
- **Cancellation** – cooperative cancellation via `RpcCancellationToken`.
- **Traceability** – trace IDs, correlation IDs, and domain metadata for
  observability.

## Creating and cloning contexts

### From scratch

```dart
final ctx = RpcContextBuilder()
    .withGeneratedTraceId()
    .withHeader('x-user-id', user.id)
    .withTimeout(const Duration(seconds: 3))
    .build();
```

### Inheriting from a parent

```dart
final child = RpcContextBuilder.inheritFrom(parentContext)
    .withHeader('x-request-source', 'checkout')
    .withTimeout(const Duration(milliseconds: 600))
    .build();
```

### Quick factories

```dart
final authCtx = RpcContextUtils.withBearerToken(token);
final traced = RpcContextUtils.withTracing(traceId: 'trace-1234');
final domain = RpcContext.forDomainCall(
  parentContext: traced,
  fromDomain: 'Order',
  toDomain: 'User',
  operation: 'GetUserProfile',
);
```

## Passing metadata to responders

Every call automatically receives the context in handler signatures:

```dart
Future<User> getUser(GetUserRequest request, {RpcContext? context}) async {
  final traceId = context?.traceId;
  final locale = context?.getHeader('x-locale') ?? 'en';

  if (context?.isCancelled ?? false) {
    throw RpcCancelledException('Client aborted the request');
  }

  return userRepository.fetch(request.id, locale: locale, traceId: traceId);
}
```

Because `RpcContext` is immutable you can create derived copies whenever you
need to add or override metadata.

```dart
final retryCtx = context
    ?.withAdditionalHeaders({'x-retry-count': '2'})
    .withTimeout(const Duration(seconds: 1));
```

## Deadlines and cancellation

- `RpcContext.withTimeout` or `.withDeadline` attach temporal limits. They are
  honoured on both sides: callers stop waiting and responders can short-circuit
  expensive work.
- `RpcCancellationToken` provides cooperative cancellation. The caller creates a
  token, passes it into the context, and keeps a handle to `token.cancel()`.
- `RpcDeadlineExceededException` and `RpcCancelledException` make it explicit
  why a call was terminated early.

```dart
final token = RpcCancellationToken();
final ctx = RpcContextBuilder()
    .withCancellation(token)
    .withTimeout(const Duration(seconds: 2))
    .build();

final future = calculator.callSomething(request, context: ctx);

// Cancel from the UI after 500ms
Future.delayed(const Duration(milliseconds: 500), () => token.cancel('User left page'));
```

## Context chains for orchestration

When a workflow spans multiple domains you rarely want to re-create metadata
from scratch. `RpcContext.createChain` generates a sequence of derived contexts
with fresh request IDs while preserving headers and trace IDs:

```dart
final base = RpcContext.forBusinessOperation(
  operationType: 'PlaceOrder',
  userId: user.id,
  sessionId: session.id,
);

final chain = RpcContext.createChain(
  base,
  steps: ['Inventory', 'Payment', 'Notifications'],
  stepTimeout: const Duration(seconds: 5),
);

await inventoryCaller.reserve(itemId, context: chain['Inventory']);
await paymentCaller.charge(paymentId, context: chain['Payment']);
```

## Sanitising and merging metadata

- `RpcContext.sanitize` removes sensitive headers such as `authorization` and
  cookies before you log or persist the context.
- `RpcContextUtils.merge` combines two contexts, letting the right-hand side take
  precedence for overlapping headers or deadlines.
- Extensions like `RpcContext.createChildWith` make it trivial to fork contexts
  with a few overrides, ideal for fan-out operations.

## Surfacing domain metadata

`RpcContext.extractDomainMetadata` summarises business identifiers (user IDs,
tenant IDs, operation names, trace IDs). You can feed it to structured logging
or metrics without manually parsing headers each time.

By embracing `RpcContext` you create a consistent experience across transports
and services: every RPC carries enough information to authenticate, trace, and
control its execution without ad-hoc plumbing.
