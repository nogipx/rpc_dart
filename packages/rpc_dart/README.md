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

### Testing

- Unit: mock Caller interfaces.
- Integration: RpcInMemoryTransport.pair() for end-to-end tests.

### Additional resources

- Extra transports and examples: package [rpc_dart_transports](https://pub.dev/packages/rpc_dart_transports).

