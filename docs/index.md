# rpc_dart

`rpc_dart` is a transport-agnostic RPC framework for Dart. Write your service contracts once and run them over any transport — in-process, HTTP/2, WebSocket, or Dart Isolates — without changing the service code. It uses gRPC-compatible 5-byte message framing and supports all four RPC call patterns.

[pub.dev](https://pub.dev/packages/rpc_dart){ .md-button } [DeepWiki](https://deepwiki.com/nogipx/rpc_dart){ .md-button } [Context7](https://context7.com/nogipx/rpc_dart){ .md-button }

---

## RPC Patterns

| Pattern | Signature |
|---|---|
| Unary | `Future<Response> method(Request)` |
| Server streaming | `Stream<Response> method(Request)` |
| Client streaming | `Future<Response> method(Stream<Request>)` |
| Bidirectional streaming | `Stream<Response> method(Stream<Request>)` |

---

## Packages

| Package | Description |
|---|---|
| [`rpc_dart`](https://pub.dev/packages/rpc_dart) | Core framework: contracts, endpoints, transports interface, context |
| [`rpc_dart_generator`](https://pub.dev/packages/rpc_dart_generator) | `build_runner` code generator — turns annotated interfaces into ready-to-use responders and callers |
| [`rpc_dart_compression`](https://pub.dev/packages/rpc_dart_compression) | Cross-platform gzip codec (works on web/wasm) |
| [`rpc_dart_opentelemetry`](https://pub.dev/packages/rpc_dart_opentelemetry) | OpenTelemetry interceptor with W3C Trace Context propagation |
| [`rpc_dart_http2`](https://pub.dev/packages/rpc_dart_http2) | HTTP/2 transport (native) |
| [`rpc_dart_http`](https://pub.dev/packages/rpc_dart_http) | HTTP/1.1 transport (cross-platform, web/wasm) |
| [`rpc_dart_websocket`](https://pub.dev/packages/rpc_dart_websocket) | WebSocket transport (cross-platform) |
| [`rpc_dart_isolate`](https://pub.dev/packages/rpc_dart_isolate) | Dart Isolate transport (IO + web workers) |

---

## Installation

```yaml
dependencies:
  rpc_dart: ^2.6.1

dev_dependencies:
  rpc_dart_generator: ^0.1.6
  build_runner: any
```

---

## Minimal Example

The shortest path to a working RPC call — unary, in-process, zero-copy (no serialization):

```dart
import 'package:rpc_dart/rpc_dart.dart';

// Shared types
class AddRequest  { final int a, b; AddRequest(this.a, this.b); }
class AddResponse { final int result; AddResponse(this.result); }

// Server contract
final class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super('Calculator');

  @override
  void setup() {
    addUnaryMethod<AddRequest, AddResponse>(
      methodName: 'add',
      handler: (req, {context}) async => AddResponse(req.a + req.b),
    );
  }
}

void main() async {
  final (callerTransport, responderTransport) = RpcInMemoryTransport.pair();

  final server = RpcResponderEndpoint(transport: responderTransport);
  server.registerServiceContract(CalculatorResponder());
  server.start();

  final callerEndpoint = RpcCallerEndpoint(transport: callerTransport);

  final response = await callerEndpoint.unaryRequest<AddRequest, AddResponse>(
    serviceName: 'Calculator',
    methodName: 'add',
    request: AddRequest(2, 3),
  );

  print(response.result); // 5
}
```

For real projects use the [code generator](core/generator.md) to avoid writing boilerplate. See the [Getting Started guide](getting-started.md) for a full walkthrough.