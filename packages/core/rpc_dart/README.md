<div style="text-align: center;">
  <h1>
    <p>RPC Dart</p>
    <p>
        <a href="https://pub.dev/packages/rpc_dart"><img src="https://img.shields.io/pub/v/rpc_dart.svg" alt="Pub Version"></a>
        <a href="https://github.com/nogipx/rpc_dart/actions/workflows/ci.yml"><img src="https://github.com/nogipx/rpc_dart/workflows/CI/badge.svg" alt="CI"></a>
        <a href="https://coveralls.io/github/nogipx/rpc_dart?branch=main"><img src="https://coveralls.io/repos/github/nogipx/rpc_dart/badge.svg?branch=main" alt="Coverage Status"></a>
        <a href="https://deepwiki.com/nogipx/rpc_dart"><img alt="DeepWiki" src="https://img.shields.io/badge/DeepWiki-4AA6D2?logo=wikipedia&link=https%3A%2F%2Fdeepwiki.com%2Fnogipx%2Frpc_dart"></a>
    </p>
  </h1>
</div>

### Core concepts

- Contracts — service name and method identifiers defining the API.
- Responder — server side: registers methods and handles requests.
- Caller — client side: invokes methods via an endpoint.
- Endpoint — connection point that uses a transport to send/receive messages.
- Transport — message transport implementation (InMemory, Isolate, HTTP, WebSocket, etc.).
- Codecs — optional serializers/deserializers for requests and responses.

### Key features

- Unary calls, server streams, client streams, and bidirectional streams.
- RpcInMemoryTransport with zero-copy support for in-process object transfer.
- Data transfer modes: zeroCopy, codec, auto (recommended).
- RpcContext carries trace id and headers.
- Endpoint and transport diagnostics via `health()` and `reconnect()` APIs.
- Built-in primitive wrappers: RpcString, RpcInt, RpcDouble, RpcBool, RpcList.
- Pure Dart, no external dependencies.
- Easy testing with InMemory transport and mocks.

### Quick start

* Define contract and models
```dart
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodCalculate = 'calculate';
}

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

* Implement Responder

```dart
final class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super(ICalculatorContract.name);

  @override
  void setup() {
    addUnaryMethod<Request, Response>(
      methodName: ICalculatorContract.methodCalculate,
      handler: calculate,
    );
  }

  Future<Response> calculate(Request req, {RpcContext? context}) async {
    final result = req.op == 'add' ? req.a + req.b : 0.0;
    return Response(result);
  }
}
```

* Implement Caller

```dart
final class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint) : super(ICalculatorContract.name, endpoint);

  Future<Response> calculate(Request request) {
    return callUnary<Request, Response>(
      methodName: ICalculatorContract.methodCalculate,
      request: request,
    );
  }
}
```

* Run with InMemory transport

```dart
void main() async {
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  final responderEndpoint = RpcResponderEndpoint(transport: serverTransport);
  final callerEndpoint = RpcCallerEndpoint(transport: clientTransport);

  responderEndpoint.registerServiceContract(CalculatorResponder());
  responderEndpoint.start();

  final calculator = CalculatorCaller(callerEndpoint);
  final res = await calculator.calculate(Request(10, 5, 'add'));
  print(res.result); // 15.0

  await callerEndpoint.close();
  await responderEndpoint.close();
}
```

### Health monitoring

RPC endpoints expose aggregated diagnostics that combine endpoint state and
transport status. Use `health()` to retrieve a snapshot and `reconnect()` to
delegate recovery to the underlying transport:

```dart
final report = await callerEndpoint.health();
if (!report.isHealthy) {
  print('Transport issue: ${report.transportStatus?.message}');
}

await callerEndpoint.reconnect();
```

#### Data transfer modes

- zeroCopy — object transfer without serialization (supported by compatible transports).
- codec — force serialization using provided codecs.
- auto — automatic choice: no codecs → zero-copy, codecs present → serialization.

#### Routing

RpcTransportRouter routes calls to different transports by service name, headers, or custom predicates. Rules support priorities. Use the router as a transport for CallerEndpoint.

#### StreamDistributor

Manages server streams: create client streams, publish messages, filter recipients, auto-clean inactive streams, expose metrics. Use for notifications, chat, and live updates.

#### Errors and metadata

- Use RpcException and RpcStatus for error propagation.
- RpcContext carries headers, trace id and other metadata.

#### Cancellation and deadlines (cooperative)

RPC Dart uses cooperative cancellation:

- The framework can stop routing messages for a cancelled call and will clean up internal stream state.
- Your business handler must *cooperate* by checking `RpcContext` (`cancellationToken` / `deadline`) and exiting early, otherwise it may keep running and hold resources.

Client-side:

```dart
final token = RpcCancellationToken();
final ctx = RpcContext.withCancellation(token).withTimeout(const Duration(seconds: 2));

final future = callerEndpoint.unaryRequest<RpcString, RpcString>(
  serviceName: 'MyService',
  methodName: 'LongOperation',
  requestCodec: RpcString.codec,
  responseCodec: RpcString.codec,
  request: const RpcString('start'),
  context: ctx,
);

token.cancel('User requested cancel');
await future; // throws RpcCancelledException (if handler cooperates)
```

Server-side (handler):

```dart
Future<RpcString> longOperation(RpcString request, {RpcContext? context}) async {
  for (var i = 0; i < 1000; i++) {
    context?.cancellationToken?.throwIfCancelled();
    if (context?.isExpired == true) {
      throw RpcDeadlineExceededException(context!.deadline!, Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return const RpcString('done');
}
```

### Testing

- Unit: mock Caller interfaces.
- Integration: RpcInMemoryTransport.pair() for end-to-end tests.

### Additional resources

- Extra transports and examples: package [rpc_dart_transports](https://pub.dev/packages/rpc_dart_transports).
