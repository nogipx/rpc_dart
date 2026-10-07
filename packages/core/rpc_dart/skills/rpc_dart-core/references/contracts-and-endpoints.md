<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Contracts and endpoints

A **contract** names a service and its methods; an **endpoint** binds
contracts to one transport. Server: `RpcResponderContract` on an
`RpcResponderEndpoint`. Client: `RpcCallerContract` on an `RpcCallerEndpoint`.
Both directions over one transport: `RpcPeerContract` on an `RpcPeerEndpoint`.

## Rules

- `RpcResponderContract`, `RpcCallerContract` and `RpcPeerContract` are
  **abstract**: subclass them. The service name is the first positional
  constructor argument; there is no zero-argument constructor.
- Register responder methods in `setup()`. Do not call it yourself:
  `registerServiceContract` calls it when the contract has no methods yet.
- Every handler takes a named `{RpcContext? context}` parameter.
- Each method name once per contract, each service name once per endpoint;
  duplicates throw `RpcStatusException` (`RpcStatus.internal`).
- Service names: letters, digits, `_`, `-`, `.`. Method names: letters, digits,
  `_`, `-` (no dot). Anything else throws at registration.
- Pass both codecs or neither; no codecs means zero-copy, which needs
  `transport.supportsZeroCopy` (see `codecs-and-compression.md`).
- `RpcCallerEndpoint` needs a client transport (`isClient == true`),
  `RpcResponderEndpoint` a server one; the wrong one throws `ArgumentError` in
  the constructor. `RpcPeerEndpoint` accepts either.
- Call `start()` on responder and peer endpoints after registering contracts.
  Without it incoming calls are never handled. `RpcCallerEndpoint` needs no
  `start()`.
- `close()` closes the transport and calls `dispose()` on every registered
  contract. A server endpoint lives for ONE connection, so `dispose()` may only
  release what the contract created itself, never shared pools or singletons.

## Responder contract

`RpcResponderContract(String serviceName, {RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto})`.
Each `add*` takes `methodName:` and `handler:` (required), `requestCodec:`,
`responseCodec:`, `description:`. Override `dispose()` for cleanup.

| Method | Handler type |
| --- | --- |
| `addUnaryMethod<Req, Res>` | `Future<Res> Function(Req, {RpcContext? context})` |
| `addServerStreamMethod<Req, Res>` | `Stream<Res> Function(Req, {RpcContext? context})` |
| `addClientStreamMethod<Req, Res>` | `Future<Res> Function(Stream<Req>, {RpcContext? context})` |
| `addBidirectionalMethod<Req, Res>` | `Stream<Res> Function(Stream<Req>, {RpcContext? context})` |

```dart
const greeterService = 'Greeter';

final class GreeterResponder extends RpcResponderContract {
  GreeterResponder() : super(greeterService);

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'hello',
      handler: _hello,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
    addClientStreamMethod<RpcInt, RpcInt>(
      methodName: 'sum',
      handler: _sum,
      requestCodec: RpcInt.codec,
      responseCodec: RpcInt.codec,
    );
  }

  Future<RpcString> _hello(RpcString request, {RpcContext? context}) async =>
      RpcString('Hello, ${request.value}');

  Future<RpcInt> _sum(Stream<RpcInt> requests, {RpcContext? context}) async {
    var total = 0;
    await for (final r in requests) {
      total += r.value;
    }
    return RpcInt(total);
  }
}
```

## Caller contract

`RpcCallerContract(String serviceName, RpcCallerEndpoint endpoint, {RpcDataTransferMode dataTransferMode = RpcDataTransferMode.auto})`.
Call helpers: `callUnary`, `callServerStream`, `callClientStream`,
`callBidirectionalStream` (named: `methodName:`, `request:` or `requests:`,
`requestCodec:`, `responseCodec:`, `context:`). Also `cancelMethod(name)`,
`cancelAllMethods()`, `isMethodActive(name)`, `getActiveCallsCount(name)`.

```dart
final class GreeterCaller extends RpcCallerContract {
  GreeterCaller(RpcCallerEndpoint endpoint) : super(greeterService, endpoint);

  Future<RpcString> hello(RpcString request, {RpcContext? context}) =>
      callUnary<RpcString, RpcString>(
        methodName: 'hello',
        request: request,
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        context: context,
      );

  Future<RpcInt> sum(Stream<RpcInt> values) => callClientStream<RpcInt, RpcInt>(
    methodName: 'sum',
    requests: values,
    requestCodec: RpcInt.codec,
    responseCodec: RpcInt.codec,
  );
}
```

## Endpoints

| Endpoint | Constructor | Own API |
| --- | --- | --- |
| `RpcResponderEndpoint` | `transport:` (required), `debugLabel:`, `logger:` (`LogController?`) | `registerServiceContract(c)`, `unregisterServiceContract(name)`, `start()`, `markDraining()`, `drain({timeout})` |
| `RpcCallerEndpoint` | `transport:` (required), `debugLabel:`, `logger:` (`LogController?`), `compressionEnabled:` (default `false`) | `cancelMethod`, `cancelServiceMethods`; `close()` cancels in-flight calls |
| `RpcPeerEndpoint` | same as caller | union of both; needs `start()` |

All endpoints: `addMiddleware`, `addInterceptor`, `close()`, `health()`,
`reconnect()`, `isActive`, `transport`. There are no `interceptors:` /
`middlewares:` constructor parameters.

Endpoints also have an untyped call API (`unaryRequest`, `serverStream`,
`clientStream` returning a `Future<R> Function(Stream<C>)` builder,
`bidirectionalStream`; each takes `serviceName:`, `methodName:`). Prefer caller
contracts: they validate codecs against the transfer mode.

`markDraining()` refuses new streams with `UNAVAILABLE` and leaves running ones
alone; `drain()` also cancels active handlers and waits up to `timeout`. Server
bootstraps in transport packages call these for you.

```dart
Future<void> runGreeter() async {
  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();

  final server = RpcResponderEndpoint(transport: serverTransport);
  server.registerServiceContract(GreeterResponder());
  server.start();

  final client = RpcCallerEndpoint(transport: clientTransport);
  final greeter = GreeterCaller(client);
  final reply = await greeter.hello(const RpcString('Ada'));
  final total = await greeter.sum(Stream.fromIterable([RpcInt(1), RpcInt(2)]));
  assert(reply.value == 'Hello, Ada' && total.value == 3);

  await client.close();
  await server.close();
}
```

## Peer endpoint and peer contract

One transport, calls in both directions. Stream-id parity separates them: the
`isClient == true` side opens odd ids, the other side even ids, and each
responder half handles only ids the remote opened. The two ends must therefore
have opposite `isClient` values, as `memoryPair()` returns them.

`RpcPeerContract(serviceName, RpcPeerEndpoint endpoint, {responderDataTransferMode, callerDataTransferMode})`
extends `RpcResponderContract`: register handlers in `setup()`, call the remote
with `callUnary` / `callServerStream` / `callClientStream` /
`callBidirectionalStream`.

```dart
final class ChatPeer extends RpcPeerContract {
  ChatPeer(RpcPeerEndpoint endpoint) : super('Chat', endpoint);

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      handler: (req, {context}) async => RpcString('pong ${req.value}'),
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> ping(String text) => callUnary<RpcString, RpcString>(
    methodName: 'ping',
    request: RpcString(text),
    requestCodec: RpcString.codec,
    responseCodec: RpcString.codec,
  );
}

Future<void> runPeers() async {
  final (a, b) = RpcChannelTransport.memoryPair();
  final left = RpcPeerEndpoint(transport: a);
  final right = RpcPeerEndpoint(transport: b);
  final leftChat = ChatPeer(left);
  final rightChat = ChatPeer(right);
  left
    ..registerServiceContract(leftChat)
    ..start();
  right
    ..registerServiceContract(rightChat)
    ..start();
  await leftChat.ping('from left');
  await rightChat.ping('from right');
  await left.close();
}
```

## Middleware vs interceptors

Both run on caller and responder endpoints, for all four call shapes, and the
set is fixed when a call starts.

| | `IRpcMiddleware` | `IRpcInterceptor` |
| --- | --- | --- |
| Hooks | `processRequest<T>(RpcMiddlewareContext call, T request)`, `processResponse<T>(call, T response)`; return `FutureOr<T>` | `interceptUnary(call, request, next)`, `interceptServerStream(call, request, next)`, `interceptClientStream(call, requests, next)`, `interceptBidirectionalStream(call, requests, next)` |
| On streams | runs per message | sees the whole stream |
| Short-circuit | only by throwing | return without calling `next` |
| Register | `endpoint.addMiddleware(m)` | `endpoint.addInterceptor(i)` |
| Order | requests in add order, responses reversed | first added is outermost |

Per call: request middlewares, then interceptors, then the handler (on a caller
endpoint: the wire), then response middlewares. Defaults pass through; override
only what you need. `RpcMiddlewareContext` has `endpoint`, `serviceName`,
`methodName` and a mutable `context`. `next` takes `(RpcContext, request)`;
pass `call.context` to keep the current one.

```dart
import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

final class TrimMiddleware extends IRpcMiddleware {
  const TrimMiddleware();

  @override
  FutureOr<TRequest> processRequest<TRequest>(
    RpcMiddlewareContext call,
    TRequest request,
  ) {
    if (request is RpcString) {
      return RpcString(request.value.trim()) as TRequest;
    }
    return request;
  }
}

final class RequireTokenInterceptor extends IRpcInterceptor {
  const RequireTokenInterceptor();

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    if (call.context.getHeader('authorization') == null) {
      throw RpcStatusException(RpcStatus.unauthenticated, 'missing token');
    }
    return next(call.context, request);
  }
}

void wireChain(RpcResponderEndpoint server) {
  server
    ..addMiddleware(const TrimMiddleware())
    ..addInterceptor(const RequireTokenInterceptor());
}
```

Retry and circuit-breaker
interceptors: `errors-and-resilience.md`. Headers and `RpcContext`:
`context-and-metadata.md`.

## Code-generation annotations

Declared in core so annotated interfaces compile without the generator. Run
generation with the `rpc_dart_generator` package (see its README).

| Annotation | Declares |
| --- | --- |
| `@RpcService(name:, kind:, transferMode:, description:, grpcDescriptor:)` | A service. `name` is the wire service name. `kind`: `RpcServiceKind.unidirectional` (default: caller + responder) or `RpcServiceKind.peer` (peer contracts). `transferMode` defaults to `auto`. `grpcDescriptor: true` also emits a descriptor for gRPC server reflection. |
| `@RpcMethod.unary(name:)`, `.serverStream`, `.clientStream`, `.bidirectionalStream`, or `@RpcMethod(name:, kind:)` | A method's wire name and shape. Optional `description:`, `requestCodec:` / `responseCodec:` (a `Type` with a const constructor), `transferMode:`. |
| `@RpcRemoved([message])` | An inherited method removed in this version: generated code is `@Deprecated` and throws `UnsupportedError`. |

```dart
@RpcService(name: 'Greeter')
abstract interface class IGreeter {
  @RpcMethod.unary(name: 'hello')
  Future<RpcString> hello(RpcString request, {RpcContext? context});
}

@RpcService(name: 'Greeter.v2')
abstract interface class IGreeterV2 implements IGreeter {
  @RpcRemoved('Use helloV2 instead.')
  @override
  Future<RpcString> hello(RpcString request, {RpcContext? context});

  @RpcMethod.unary(name: 'helloV2')
  Future<RpcString> helloV2(RpcString request, {RpcContext? context});
}
```

Versioning: a new version is a new interface with a new service name that
`implements` the previous one. Each version is a separate service on the wire,
and the generated versioned responder handles only its own methods, so keep
the older responders registered while old callers exist.

## Pitfalls

- `RpcCallerContract(...)` cannot be instantiated; write a subclass.
- `callUnary` is on the contract; the endpoint's method is `unaryRequest`.
- Zero-copy (no codecs) on a transport without `supportsZeroCopy` throws
  `ArgumentError`; for unary and server-stream calls it is thrown synchronously
  by the call, not delivered through the Future/Stream.
- A streaming handler that uses `requests.listen(...)` must pass `onError`:
  cancellation and deadlines arrive as stream errors. Prefer `await for`.
- Two peer endpoints whose transports have the same `isClient` collide on ids.
