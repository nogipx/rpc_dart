# HTTP/1.1 Transport

`rpc_dart_http` provides an HTTP/1.1 transport built on [`package:http`](https://pub.dev/packages/http) (caller) and [`package:shelf`](https://pub.dev/packages/shelf) (responder). It compiles to all platforms including JS and Wasm.

!!! warning "Unary only"
    HTTP/1.1 cannot multiplex messages in both directions within a single request/response cycle. Only **unary** RPC methods are supported. For streaming over web, use [WebSocket](websocket.md).

---

## Installation

```yaml
dependencies:
  rpc_dart_http: <latest>
```

---

## Client

```dart
import 'package:rpc_dart_http/rpc_dart_http.dart';

final transport = RpcHttpCallerTransport(
  baseUrl: 'https://api.example.com',
);

final caller = CalculatorContractCaller(
  RpcCallerEndpoint(transport: transport),
);

final result = await caller.sum(SumRequest(values: [1, 2, 3]));

await caller.endpoint.close();
```

### Custom HTTP client

Pass a custom `http.Client` to configure TLS, proxies, or timeouts. On native platforms you can wrap `dart:io`'s `HttpClient`:

```dart
import 'dart:io';
import 'package:http/io_client.dart';

final ioClient = HttpClient()
  ..badCertificateCallback = (cert, host, port) => true; // dev only

final transport = RpcHttpCallerTransport(
  baseUrl: 'https://localhost:8080',
  httpClient: IOClient(ioClient),
);
```

---

## Server

`RpcHttpResponderTransport` exposes a shelf `handler`. Mount it on any shelf server or router:

```dart
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

final transport = RpcHttpResponderTransport();

final server = RpcResponderEndpoint(transport: transport);
server.registerServiceContract(CalculatorResponder());
server.start();

// Serve the shelf handler
await shelf_io.serve(transport.handler, '0.0.0.0', 8080);
```

### CORS

For browser clients, pass a `RpcHttpCorsPolicy`:

```dart
final transport = RpcHttpResponderTransport(
  corsPolicy: RpcHttpCorsPolicy(
    allowedOrigins: ['https://app.example.com'],
    allowedHeaders: ['content-type', 'authorization'],
    allowCredentials: true,
    preflightMaxAge: Duration(hours: 1),
  ),
);
```

The required gRPC headers (`grpc-encoding`, `grpc-status`, `grpc-message`, etc.) are always included in `Access-Control-Expose-Headers` automatically.

To allow any origin (incompatible with `allowCredentials: true`):

```dart
RpcHttpCorsPolicy(allowedOrigins: ['*'])
```

### Body read timeout

Limit how long to wait for the full request body:

```dart
RpcHttpResponderTransport(
  bodyReadTimeout: Duration(seconds: 10),
)
```

### Security policy

```dart
RpcHttpResponderTransport(
  securityPolicy: RpcSecurityPolicy(
    maxMessageLengthBytes: 1 * 1024 * 1024, // 1 MB
  ),
)
```

---

## Wire Format

```
Request:   POST {baseUrl}/{ServiceName}/{MethodName}
           Content-Type: application/grpc
           Body: gRPC-framed bytes (5-byte prefix + payload)

Response:  200 OK
           grpc-status: 0
           Body: gRPC-framed bytes
```

HTTP status codes are mapped to gRPC status codes (e.g. `401 → UNAUTHENTICATED`, `503 → UNAVAILABLE`).