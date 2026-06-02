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

**Client side — add `OtelRpcClientInterceptor` on the caller endpoint.** It creates a `SpanKind.client` span for each outgoing call and injects `traceparent` / `tracestate` headers via `RpcOtelPropagator.inject`:

```dart
final endpoint = MyCallerEndpoint(transport: ...)
  ..addInterceptor(OtelRpcClientInterceptor(tracer: tracer));
```

**Server side — extraction is automatic.** `OtelRpcInterceptor` calls `RpcOtelPropagator.extract` internally on every incoming call, so the span created on the server is automatically linked to the parent span from the caller.

For ad-hoc usage (no interceptor), the lower-level helper is still available:

```dart
final ctx = RpcOtelPropagator.inject(RpcContext.empty());
final response = await caller.myMethod(request, context: ctx);
```

---

## Metrics (optional)

Pass a `RpcOtelMetrics` instance to record per-call counters labelled by gRPC status code:

```dart
import 'package:opentelemetry/api.dart';

final meter = globalMeterProvider.getMeter('my-service');

endpoint.addInterceptor(OtelRpcInterceptor(
  tracer: tracer,
  metrics: RpcOtelMetrics(meter: meter),
));
```

Metrics follow the [OpenTelemetry semantic conventions for RPC](https://opentelemetry.io/docs/specs/semconv/rpc/rpc-metrics/):

| Instrument | Type | Attributes |
|---|---|---|
| `rpc.server.requests` | Counter | `rpc.system`, `rpc.service`, `rpc.method`, `rpc.grpc.status_code` |

The `rpc.grpc.status_code` value is the canonical uppercase gRPC name (`OK`, `UNAVAILABLE`, `DEADLINE_EXCEEDED`, ...) — derived from `RpcStatusException.statusCode` when an error is thrown, or `OK` on success. Unknown codes fall back to `UNKNOWN`, keeping the label cardinality bounded.

Histogram (`rpc.server.duration`) and active-request gauge (`rpc.server.active_requests`) will be added once the OpenTelemetry Dart API exposes those instrument types.

---

## Bridging `LogController` into OpenTelemetry

`rpc_dart`'s `LogController` exposes its own span/event model. Use
`LogControllerOtelOutput` as an additional `LogOutput` to mirror every
`LogScope.withSpan(...)` block and every `LogScope.event(...)` into OTel:

```dart
final tracer = globalTracerProvider.getTracer('my-service');

final logController = LogController(outputs: [
  ConsoleOutput(),
  LogControllerOtelOutput(
    tracer: tracer,
    // Nest log-spans under the active RPC span when called from inside a handler:
    rootContextProvider: () => Context.current,
  ),
]);
```

Mapping:

| LogController record | OpenTelemetry |
|---|---|
| `LogSpanStart` | `tracer.startSpan(name, startTime, parent=…)` |
| `LogEvent` (with `spanId`) | `span.addEvent(message, attributes)` |
| `LogEvent` (standalone) | single-shot span `log.<scope>` |
| `LogSpan` (end) | sets attributes/status, then `span.end(endTime)` |

Nested `LogScope.startSpan(...)` calls become child OTel spans automatically
because `LogSpanStart` carries the `parentSpanId`. Inside an RPC handler,
the bridge's `rootContextProvider` returns the active OTel context — so a
`LogScope.withSpan('db.query', ...)` ends up as a child of the
`OtelRpcInterceptor`-created server span, and you get a single connected
trace from the caller down to your last `db.query` event in Grafana.