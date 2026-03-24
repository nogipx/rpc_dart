# OpenTelemetry

The `rpc_dart_opentelemetry` package integrates [OpenTelemetry](https://opentelemetry.io/) into rpc_dart. It wraps every RPC call in a span, propagates W3C Trace Context through `RpcContext` headers, and optionally records call metrics.

---

## Setup

```yaml
dependencies:
  rpc_dart_opentelemetry: ^0.1.0
  opentelemetry: ^0.18.0
```

### 1. Bootstrap the OTel SDK

```dart
import 'package:opentelemetry/api.dart';
import 'package:opentelemetry/sdk.dart';

// Console exporter for development; swap for CollectorExporter in production.
final tracerProvider = TracerProviderBase(
  processors: [SimpleSpanProcessor(ConsoleExporter())],
);
registerGlobalTracerProvider(tracerProvider);

// Shutdown on exit to flush buffered spans.
tracerProvider.shutdown();
```

### 2. Attach the interceptor

```dart
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';

final tracer = globalTracerProvider.getTracer('my-service', version: '1.0.0');

final endpoint = RpcResponderEndpoint(transport: transport)
  ..addInterceptor(OtelRpcInterceptor(tracer: tracer))
  ..registerServiceContract(MyResponder())
  ..start();
```

Every RPC call through this endpoint now produces a span automatically.

---

## Span Details

Each span is named `{serviceName}/{methodName}` and carries these attributes:

| Attribute | Value |
|---|---|
| `rpc.system` | `'rpc_dart'` |
| `rpc.service` | service name |
| `rpc.method` | method name |
| `rpc.call_type` | `'unary'` / `'server_stream'` / `'client_stream'` / `'bidirectional_stream'` |
| `rpc.trace_id` | value from `RpcContext.traceId` (if present) |

For streaming calls, `rpc.stream.messages` is added on completion with the total message count.

On error, the span records the exception and sets status to `StatusCode.error`.

---

## Accessing the Span in Handlers

The interceptor stores the active span in `RpcContext` under `OtelRpcKeys.span`. Retrieve it in any handler to add custom attributes:

```dart
Future<Response> handle(Request request, {RpcContext? context}) async {
  final span = context?.getValue(OtelRpcKeys.span) as Span?;
  span?.setAttribute(Attribute.fromString('user.id', request.userId));
  span?.setAttribute(Attribute.fromInt('items.count', request.items.length));

  // ...
}
```

---

## W3C Trace Context Propagation

Use `RpcOtelPropagator` to propagate trace context across service boundaries via `traceparent` / `tracestate` headers.

**Client side — inject active span into outgoing context:**

```dart
// Wrap the context before passing it to a caller method.
final ctx = RpcOtelPropagator.inject(RpcContext.empty());
final response = await caller.myMethod(request, context: ctx);
```

**Server side — extraction is automatic.** `OtelRpcInterceptor` calls `RpcOtelPropagator.extract` internally on every incoming call, so the span created on the server is automatically linked to the parent span from the caller.

---

## Metrics (optional)

Pass a `RpcOtelMetrics` instance to record call counts and error counts:

```dart
import 'package:opentelemetry/api.dart';

final meter = globalMeterProvider.getMeter('my-service');

endpoint.addInterceptor(OtelRpcInterceptor(
  tracer: tracer,
  metrics: RpcOtelMetrics(meter: meter),
));
```

Two instruments are recorded per call:

| Instrument | Type | Attributes |
|---|---|---|
| `rpc_dart.calls.total` | Counter | `rpc.system`, `rpc.service`, `rpc.method` |
| `rpc_dart.errors.total` | Counter | same |