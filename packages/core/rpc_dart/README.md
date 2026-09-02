<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

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

Transport-agnostic RPC framework for Dart. Implements the gRPC wire protocol — works over HTTP/2, WebSocket, Isolates, and in-memory without code changes.

---

## Core concepts

- **Contract** — service name and method identifiers defining the API.
- **Responder** — server side: registers methods and handles requests.
- **Caller** — client side: invokes methods via an endpoint.
- **Endpoint** — connection point that wraps a transport.
- **Transport** — message transport (InMemory, Isolate, HTTP/2, WebSocket, etc.).
- **Codec** — optional serializer/deserializer for requests and responses.

## Key features

- Unary, server streaming, client streaming, bidirectional streaming.
- Zero-copy in-process transport (`RpcInMemoryTransport`).
- 3-layer transport architecture: `IRpcChannel` → `IRpcMultiplexedChannel` → `IRpcTransport`.
- Resilience: retry, circuit breaker, rate limiter, reconnect state machine.
- Per-stream and connection-wide flow control, on by default.
- Security policy: bounds on metadata, message size and concurrent streams.
- gRPC Health Checking Protocol (`grpc.health.v1`).
- `RpcBinaryCodec` for protobuf and other binary formats.
- `RpcContext` with trace id, headers, deadline, cancellation.
- Pure Dart core — no external runtime dependencies.

---

## Quick start

Define a contract:

```dart
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodSum = 'sum';
}

class SumRequest {
  final List<double> values;
  SumRequest(this.values);
  factory SumRequest.fromJson(Map<String, dynamic> j) =>
      SumRequest((j['values'] as List).cast<double>());
  Map<String, dynamic> toJson() => {'values': values};
}

class SumResponse {
  final double result;
  SumResponse(this.result);
  factory SumResponse.fromJson(Map<String, dynamic> j) =>
      SumResponse(j['result'] as double);
  Map<String, dynamic> toJson() => {'result': result};
}
```

Implement the responder:

```dart
class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super(ICalculatorContract.name) {
    addUnaryMethod<SumRequest, SumResponse>(
      methodName: ICalculatorContract.methodSum,
      requestCodec: RpcCodec.withDecoder(SumRequest.fromJson),
      responseCodec: RpcCodec.withDecoder(SumResponse.fromJson),
      handler: (req, {context}) async {
        final total = req.values.fold<double>(0, (a, b) => a + b);
        return SumResponse(total);
      },
    );
  }
}
```

Run with in-memory transport:

```dart
void main() async {
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(CalculatorResponder());
  responder.start();

  final caller = RpcCallerEndpoint(transport: clientTransport);
  final res = await caller.callUnary<SumRequest, SumResponse>(
    serviceName: ICalculatorContract.name,
    methodName: ICalculatorContract.methodSum,
    requestCodec: RpcCodec.withDecoder(SumRequest.fromJson),
    responseCodec: RpcCodec.withDecoder(SumResponse.fromJson),
    request: SumRequest([1, 2, 3]),
  );
  print(res.result); // 6.0

  await caller.close();
  await responder.close();
}
```

> Use [rpc_dart_generator](https://pub.dev/packages/rpc_dart_generator) to generate caller/responder boilerplate from annotated Dart interfaces.

---

## Protobuf / binary codecs

`RpcBinaryCodec` works with any type — use it for protobuf or any custom binary format:

```dart
final reqCodec = RpcBinaryCodec<MyRequest>(
  toBytes: (r) => r.writeToBuffer(),
  fromBytes: MyRequest.fromBuffer,
);
```

---

## Resilience

### Retry

```dart
final caller = RpcCallerEndpoint(
  transport: transport,
  interceptors: [
    RpcRetryInterceptor(
      maxAttempts: 3,
      backoff: BackoffPolicy.exponential(
        initial: Duration(milliseconds: 100),
        multiplier: 2,
      ),
    ),
  ],
);
```

### Circuit breaker

```dart
RpcCircuitBreakerInterceptor(
  failureThreshold: 5,
  resetTimeout: Duration(seconds: 30),
)
```

### Client connection with reconnect

```dart
final connection = RpcClientConnection(
  transportFactory: () => RpcHttp2Transport(...),
  reconnectPolicy: BackoffPolicy.exponential(...),
);
await connection.connect();
```

### Rate limiter

```dart
final limiter = RpcRateLimiter(
  maxRequests: 100,
  window: Duration(seconds: 1),
  keyExtractor: (context) => context.header('user-id'),
);
```

---

## gRPC Health Checking

Implements the standard `grpc.health.v1.Health` protocol:

```dart
final health = RpcGrpcHealthService();
health.setStatus('MyService', ServingStatus.serving);
responder.registerServiceContract(health);

// Client:
final client = RpcGrpcHealthClient(caller);
final status = await client.check('MyService');
```

---

## Transport architecture

A 3-layer architecture:

```
IRpcChannel              — raw byte pipe (WebSocket, TCP, etc.)
IRpcMultiplexedChannel   — multiplexed framed messages
IRpcTransport            — full transport with stream IDs and health
```

Convenience factories on `RpcChannelTransport`:

```dart
// Zero-copy in-memory pair (tests, isolates):
final (t1, t2) = RpcChannelTransport.memoryPair();

// Frame-based pair (exercises full codec path):
final (t1, t2) = RpcChannelTransport.pair();

// Wrap any IRpcChannel (WebSocket, TCP):
final transport = RpcChannelTransport.fromChannel(myChannel);
```

---

## Flow control and resource limits

Both are configured through `RpcSecurityPolicy`, which any
`RpcChannelTransport` accepts. The defaults are safe for a server exposed to
untrusted peers; you only need to touch them to relax or tighten.

### Flow control

A slow or absent consumer must not let a producer pin memory. Each stream has a
window, and all streams on a connection share a second one:

```dart
final (client, server) = RpcChannelTransport.pair(
  policy: RpcSecurityPolicy(
    flowControlWindowBytes: 4 * 1024 * 1024,            // per stream
    flowControlConnectionWindowBytes: 64 * 1024 * 1024, // whole connection
  ),
);
```

The sender blocks once its window is used up and resumes as the receiving
application consumes. Credit travels on bare metadata frames, which a peer that
predates this ignores — a mixed-version pair simply falls back to the old
unbounded behaviour rather than deadlocking.

Set either to `null` to disable. **HTTP/2 has its own flow control**, so
`rpc_dart_http2` should disable these rather than run two windows over each
other.

### Resource limits

```dart
const policy = RpcSecurityPolicy(
  maxActiveStreams: 4096,          // concurrent streams, per connection
  maxMessageLengthBytes: 16 << 20, // single message, framing included
  maxMetadataBytes: 64 * 1024,
  maxHeaders: 128,
  halfOpenStreamTimeout: Duration(seconds: 60),
  closeOnProtocolError: true,
);
```

`maxActiveStreams` applies to streams the peer opens, not just your own calls.
`halfOpenStreamTimeout` reclaims a stream that was opened but never carried a
request — set it to `null` to disable. Note it covers dispatch only: a stream
that has reached a handler and then goes idle is deliberately not reclaimed,
because that is also what a legitimate long-lived subscription looks like.

---

## Health monitoring

```dart
final report = await caller.health();
if (!report.isHealthy) {
  print('issue: ${report.transportStatus?.message}');
  await caller.reconnect();
}
```

---

## Cancellation and deadlines

```dart
final token = RpcCancellationToken();
final ctx = RpcContext
    .withCancellation(token)
    .withTimeout(Duration(seconds: 2));

// In the handler, cooperate:
Future<Response> handle(Request req, {RpcContext? context}) async {
  for (final item in items) {
    context?.cancellationToken?.throwIfCancelled();
    await process(item);
  }
  return Response(...);
}

token.cancel('user cancelled');
```

---

## Error handling

Return specific gRPC status codes from handlers:

```dart
Future<Response> handle(Request req, {RpcContext? context}) async {
  if (!authorized) throw RpcStatusException(StatusCode.unauthenticated, 'Not authorized');
  return Response(...);
}
```

---

## Testing

```dart
test('sum', () async {
  final (ct, st) = RpcInMemoryTransport.pair();
  final responder = RpcResponderEndpoint(transport: st)
    ..registerServiceContract(CalculatorResponder())
    ..start();
  final caller = RpcCallerEndpoint(transport: ct);

  final res = await caller.callUnary(...);
  expect(res.result, 6.0);

  await caller.close();
  await responder.close();
});
```

---

## Ecosystem

This package is the core of the rpc_dart ecosystem. Additional packages are available:

| Package | Description |
|---|---|
| [rpc_dart_generator](https://pub.dev/packages/rpc_dart_generator) | Code generator for callers and responders |
| [rpc_dart_framework](https://pub.dev/packages/rpc_dart_framework) | Server framework: modules, DI, lifecycle, rate limiting |
| [rpc_dart_grpc_reflection](https://pub.dev/packages/rpc_dart_grpc_reflection) | gRPC Server Reflection (grpcurl, Postman support) |
| [rpc_dart_opentelemetry](https://pub.dev/packages/rpc_dart_opentelemetry) | OpenTelemetry tracing and metrics |
| [rpc_dart_http2](https://pub.dev/packages/rpc_dart_http2) | HTTP/2 transport (gRPC wire compatible) |
| [rpc_dart_websocket](https://pub.dev/packages/rpc_dart_websocket) | WebSocket transport |
| [rpc_dart_isolate](https://pub.dev/packages/rpc_dart_isolate) | Isolate transport |

For the full list visit the [GitHub repository](https://github.com/nogipx/rpc_dart).
