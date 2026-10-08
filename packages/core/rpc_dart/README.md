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

Transport-agnostic RPC framework for Dart. One contract runs over any
transport without code changes: in-process, isolates, WebSocket, HTTP/1.1, and
HTTP/2 with the real gRPC wire protocol. This package is the core; transports
other than the in-process ones live in separate packages (see
[Ecosystem](#ecosystem)).

---

## Core concepts

- **Contract** — a service name plus its methods. A responder contract
  (`RpcResponderContract`) handles calls; a caller contract
  (`RpcCallerContract`) makes them.
- **Endpoint** — binds contracts to one transport: `RpcResponderEndpoint`
  (server), `RpcCallerEndpoint` (client), `RpcPeerEndpoint` (both directions).
- **Transport** — anything implementing `IRpcTransport`.
- **Codec** — serializes requests and responses. Optional for in-process
  zero-copy transports, required on the network.

## Key features

- Unary, server streaming, client streaming, bidirectional streaming.
- Zero-copy in-process transport (`RpcChannelTransport.memoryPair()`).
- 3-layer transport architecture: `IRpcChannel` → `IRpcMultiplexedChannel` → `IRpcTransport`.
- Resilience: retry, circuit breaker, rate limiter, reconnecting client connection.
- Per-stream and connection-wide flow control, on by default.
- Security policy: bounds on metadata, message size and concurrent streams.
- gRPC Health Checking Protocol (`grpc.health.v1`).
- `RpcBinaryCodec` for protobuf and other binary formats.
- `RpcContext` with trace id, headers, deadline, cancellation.
- Pure Dart core — no runtime dependencies.

---

## Quick start

Define the messages. `RpcCodec` serializes any `IRpcSerializable` (CBOR of
`toJson()`):

```dart
import 'package:rpc_dart/rpc_dart.dart';

const calculatorService = 'Calculator';

class SumRequest implements IRpcSerializable {
  final List<double> values;
  SumRequest(this.values);

  factory SumRequest.fromJson(Map<String, dynamic> json) => SumRequest(
    (json['values'] as List).map((v) => (v as num).toDouble()).toList(),
  );

  @override
  Map<String, dynamic> toJson() => {'values': values};
}

class SumResponse implements IRpcSerializable {
  final double result;
  SumResponse(this.result);

  factory SumResponse.fromJson(Map<String, dynamic> json) =>
      SumResponse((json['result'] as num).toDouble());

  @override
  Map<String, dynamic> toJson() => {'result': result};
}
```

Implement the responder (server side) and the caller (client side):

```dart
class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super(calculatorService);

  @override
  void setup() {
    addUnaryMethod<SumRequest, SumResponse>(
      methodName: 'sum',
      requestCodec: RpcCodec.withDecoder(SumRequest.fromJson),
      responseCodec: RpcCodec.withDecoder(SumResponse.fromJson),
      handler: (request, {context}) async {
        final total = request.values.fold<double>(0, (a, b) => a + b);
        return SumResponse(total);
      },
    );
  }
}

class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint)
    : super(calculatorService, endpoint);

  Future<SumResponse> sum(SumRequest request, {RpcContext? context}) =>
      callUnary<SumRequest, SumResponse>(
        methodName: 'sum',
        request: request,
        requestCodec: RpcCodec.withDecoder(SumRequest.fromJson),
        responseCodec: RpcCodec.withDecoder(SumResponse.fromJson),
        context: context,
      );
}
```

Run them over the in-memory transport:

```dart
Future<void> main() async {
  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();

  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(CalculatorResponder());
  responder.start(); // without start() calls hang

  final caller = RpcCallerEndpoint(transport: clientTransport);
  final res = await CalculatorCaller(caller).sum(SumRequest([1, 2, 3]));
  print(res.result); // 6.0

  await caller.close();
  await responder.close();
}
```

Swap `memoryPair()` for a transport from a transport package and nothing else
changes.

> Use [rpc_dart_generator](https://pub.dev/packages/rpc_dart_generator) to generate caller/responder boilerplate from annotated Dart interfaces.

---

## Protobuf / binary codecs

`RpcBinaryCodec` adapts any byte format; the type does not need to implement
`IRpcSerializable`. With protobuf-generated classes:

```dart
final reqCodec = RpcBinaryCodec<MyRequest>(
  toBytes: (r) => r.writeToBuffer(),
  fromBytes: MyRequest.fromBuffer,
);
```

---

## Resilience

### Retry and circuit breaker

Interceptors are added with `addInterceptor`; the first one added is the
outermost. Add the circuit breaker before the retry so an open circuit fails
fast instead of being retried:

```dart
void configureCaller(RpcCallerEndpoint caller) {
  caller
    ..addInterceptor(
      RpcCircuitBreakerInterceptor(
        failureThreshold: 5,
        resetTimeout: const Duration(seconds: 30),
      ),
    )
    ..addInterceptor(
      RpcRetryInterceptor(
        maxAttempts: 3,
        backoff: const ExponentialBackoff(
          baseDelay: Duration(milliseconds: 100),
          maxDelay: Duration(seconds: 5),
        ),
      ),
    );
}
```

Retry covers unary calls only and is meant for idempotent methods. `FixedBackoff`
is the other built-in `BackoffPolicy`.

### Client connection with reconnect

`RpcClientConnection` reopens a transport after a drop. Create the endpoint once
on `connection.transport`; it stays valid across reconnects. It notices a drop
when the transport's message stream ends or errors, or, for a transport that
stays open across a drop for its own `reconnect()`, through
`IRpcConnectionLossReporting.connectionLost`:

```dart
RpcCallerEndpoint connect(Future<IRpcReconnectableTransport> Function() open) {
  final connection = RpcClientConnection(
    transportFactory: open,
    backoff: const ExponentialBackoff(maxDelay: Duration(seconds: 30)),
  );
  connection.connect(); // returns void; watch connection.state
  return RpcCallerEndpoint(transport: connection.transport);
}
```

### Rate limiter

A responder-side interceptor:

```dart
void limit(RpcResponderEndpoint responder) {
  const second = Duration(seconds: 1);
  responder.addInterceptor(
    RpcRateLimiter(
      global: const RateLimit.slidingWindow(max: 5000, window: second),
      perKeyFallback: const RateLimit.slidingWindow(max: 100, window: second),
      keyExtractor: (call) => call.context.getHeader('user-id'),
    ),
  );
}
```

A refused call fails with `RESOURCE_EXHAUSTED` plus retry info, which the
caller's default retry policy treats as transient.

---

## gRPC Health Checking

`GrpcHealthCheckContract` implements the standard `grpc.health.v1.Health`
protocol (`Check` and `Watch`), backed by a `GrpcHealthServiceStatus` you update.
The service name `''` means the whole server:

```dart
GrpcHealthServiceStatus serveHealth(RpcResponderEndpoint responder) {
  final status = GrpcHealthServiceStatus()
    ..setStatus('', GrpcServingStatus.serving)
    ..setStatus('MyService', GrpcServingStatus.serving);
  responder.registerServiceContract(GrpcHealthCheckContract(status));
  return status;
}
```

Any standard gRPC health client (for example `grpc_health_probe`) can query it
over `rpc_dart_http2`.

---

## Transport architecture

A 3-layer architecture:

```
IRpcChannel              — raw byte pipe (WebSocket, TCP, etc.)
IRpcMultiplexedChannel   — multiplexed framed messages
IRpcTransport            — full transport with stream IDs and health
```

Factories on `RpcChannelTransport`:

```dart
void transports(IRpcChannel myChannel) {
  // Zero-copy in-memory pair (tests, in-process):
  final (client, server) = RpcChannelTransport.memoryPair();

  // Frame-based pair (exercises the full codec path):
  final (frameClient, frameServer) = RpcChannelTransport.pair();

  // Wrap any IRpcChannel (WebSocket, TCP):
  final transport = RpcChannelTransport.fromChannel(
    channel: myChannel,
    isClient: true,
  );
}
```

`memoryPair()` passes objects by reference, so it skips codecs on unary calls
and never enforces byte limits. If production uses a network transport, run
your tests over `pair()` too.

---

## Flow control and resource limits

Both are configured through `RpcSecurityPolicy`, which is passed to the
transport (`memoryPair(policy:)`, `pair(policy:)`, `fromChannel(policy:)`, or a
transport package's policy parameter), not to the endpoint. The defaults are
safe for a server exposed to untrusted peers; you only need to touch them to
relax or tighten.

### Flow control

A slow or absent consumer must not let a producer pin memory. Each stream has a
window, and all streams on a connection share a second one:

```dart
final (client, server) = RpcChannelTransport.pair(
  policy: const RpcSecurityPolicy(
    flowControlWindowBytes: 4 * 1024 * 1024,            // per stream
    flowControlConnectionWindowBytes: 64 * 1024 * 1024, // whole connection
  ),
);
```

The sender blocks once its window is used up and resumes as the receiving
application consumes. Credit travels on bare metadata frames; a peer that does
not understand them ignores them, and a grace window keeps the sender from
deadlocking against such a peer.

Set either to `null` to disable. **HTTP/2 has its own flow control**, so
`rpc_dart_http2` should disable these rather than run two windows over each
other.

### Resource limits

```dart
const policy = RpcSecurityPolicy(
  maxActiveStreams: 4096,          // concurrent streams, per connection
  maxConcurrentHandlers: 256,      // handlers RUNNING, default null
  maxMessageLengthBytes: 16 << 20, // single decoded message
  maxBufferedBytes: 16 << 20,      // queued for a stream nobody is reading
  maxMetadataBytes: 64 * 1024,
  maxHeaders: 128,
  halfOpenStreamTimeout: Duration(seconds: 60),
  closeOnProtocolError: false,     // the default; a 256-violation backstop
);                                 // closes the connection either way
```

`maxActiveStreams` applies to streams the peer opens, not just your own calls.
`halfOpenStreamTimeout` reclaims a stream that was opened but never carried a
request — set it to `null` to disable. Note it covers dispatch only: a stream
that has reached a handler and then goes idle is deliberately not reclaimed,
because that is also what a legitimate long-lived subscription looks like.

`maxConcurrentHandlers` is a different dimension from `maxActiveStreams`, which
bounds stream STATE. Dart cannot interrupt a running async function, so a
handler that ignores its cancellation token keeps going after its stream is
reclaimed and its admission slot returned — a peer pacing its calls past the
reclaim grace accumulates handlers with nothing to stop them. At the ceiling a
new call is refused with `RESOURCE_EXHAUSTED`, which is retryable.

`maxBufferedBytes` bounds what is queued for a stream whose consumer is not
reading. Metadata is deliberately exempt from flow control — HTTP/2 exempts
HEADERS for the same reason, a control frame that cannot be sent deadlocks the
stream it is trying to end — so size is what bounds it. Over the limit the
stream fails with `RESOURCE_EXHAUSTED` and the connection survives.

---

## Health monitoring

Every endpoint reports its own and its transport's health:

```dart
Future<void> checkHealth(RpcCallerEndpoint caller) async {
  final report = await caller.health();
  if (!report.isHealthy) {
    print('issue: ${report.transportStatus?.message}');
  }
}
```

---

## Cancellation and deadlines

```dart
Future<void> cancellable(CalculatorCaller calculator) async {
  final token = RpcCancellationToken();
  final ctx = RpcContext.withCancellation(
    token,
  ).withTimeout(const Duration(seconds: 2));

  final pending = calculator.sum(SumRequest([1, 2]), context: ctx);
  token.cancel('user cancelled'); // the call fails with CANCELLED
  await pending.catchError((_) => SumResponse(0));
}

// In a handler, cooperate with cancellation:
Future<SumResponse> slowSum(SumRequest request, {RpcContext? context}) async {
  var total = 0.0;
  for (final value in request.values) {
    context?.cancellationToken?.throwIfCancelled();
    total += value;
  }
  return SumResponse(total);
}
```

A cancelled token poisons its context: make a new token or context per logical
operation.

---

## Error handling

Throw `RpcStatusException` with an `RpcStatus` code to send a status to the
caller. Any other exception reaches the caller as `INTERNAL`.

```dart
Future<SumResponse> guardedSum(SumRequest request, {RpcContext? context}) async {
  if (context?.getHeader('authorization') == null) {
    throw RpcStatusException(RpcStatus.unauthenticated, 'Not authorized');
  }
  return SumResponse(request.values.fold<double>(0, (a, b) => a + b));
}
```

On the caller, branch on `e.statusCode`: a status sent by the server always
arrives as a plain `RpcStatusException`.

---

## Testing

```dart
import 'package:test/test.dart';

void main() {
  test('sum', () async {
    final (ct, st) = RpcChannelTransport.memoryPair();
    final responder = RpcResponderEndpoint(transport: st)
      ..registerServiceContract(CalculatorResponder())
      ..start();
    final caller = RpcCallerEndpoint(transport: ct);

    final res = await CalculatorCaller(caller).sum(SumRequest([1, 2, 3]));
    expect(res.result, 6.0);

    await caller.close();
    await responder.close();
  });
}
```

---

## AI agents

This package ships an [Agent Skill](https://pub.dev/packages/skills) for coding
agents (Claude Code, Cursor, Copilot, Codex and others): the API reference,
rules and pitfalls, matched to the rpc_dart version your project resolves.
Install it from your project root with the
[skills](https://pub.dev/packages/skills) CLI:

```sh
dart run skills@ get
```

It is installed into your agent's skills directory, for example
`.claude/skills/` or `.agents/skills/`. If your SDK does not support
`dart run <package>@`, add `skills` as a dev dependency and run
`dart run skills get`.

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
| [rpc_dart_http](https://pub.dev/packages/rpc_dart_http) | HTTP/1.1 transport |
| [rpc_dart_websocket](https://pub.dev/packages/rpc_dart_websocket) | WebSocket transport |
| [rpc_dart_isolate](https://pub.dev/packages/rpc_dart_isolate) | Isolate transport |
| [rpc_dart_wasm](https://pub.dev/packages/rpc_dart_wasm) | WebAssembly bridge transport |

For the full list visit the [GitHub repository](https://github.com/nogipx/rpc_dart).
