<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_opentelemetry

OpenTelemetry tracing and call metrics for `rpc_dart`, built on the
[`opentelemetry`](https://pub.dev/packages/opentelemetry) package. It also
mirrors `LogController` spans and events into OTel. Logs reach the backend as
spans and span events; the OTel logs API is not used.

- `OtelRpcInterceptor` — server-side interceptor: one span per call, W3C
  `traceparent` extracted from the incoming metadata.
- `OtelRpcClientInterceptor` — caller-side counterpart, injects `traceparent`
  so the trace continues across the RPC boundary.
- `RpcOtelPropagator` — W3C trace-context extract/inject over `RpcContext`
  headers.
- `RpcOtelMetrics` — call counters and duration instruments.
- `LogControllerOtelOutput` — a `LogOutput` that turns the built-in logger's
  spans and events into OTel spans and span events.

## Install

```yaml
dependencies:
  rpc_dart_opentelemetry: ^0.4.0
  opentelemetry: ^0.18.0
```

## Setup

### 1. Bootstrap the OTel SDK

```dart
import 'package:opentelemetry/api.dart';
import 'package:opentelemetry/sdk.dart';

TracerProviderBase bootstrapTracing() {
  // ConsoleExporter is for development; use CollectorExporter in production.
  final provider = TracerProviderBase(
    processors: [SimpleSpanProcessor(ConsoleExporter())],
  );
  registerGlobalTracerProvider(provider);
  return provider;
}
```

`CollectorExporter` ships in `package:opentelemetry/sdk.dart`. It sends OTLP
over HTTP with protobuf to the exact URI you give it, so pass the collector's
HTTP port and path, not the gRPC port 4317:

```dart
TracerProviderBase otlpTracing() => TracerProviderBase(
  processors: [
    BatchSpanProcessor(
      CollectorExporter(Uri.parse('http://localhost:4318/v1/traces')),
    ),
  ],
);
```

Call `provider.shutdown()` before the process exits so buffered spans are
flushed.

### 2. Attach the interceptors

```dart
import 'package:opentelemetry/api.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';

void instrument(RpcResponderEndpoint server, RpcCallerEndpoint client) {
  final tracer = globalTracerProvider.getTracer('my-service', version: '1.0.0');

  server.addInterceptor(OtelRpcInterceptor(tracer: tracer));
  client.addInterceptor(OtelRpcClientInterceptor(tracer: tracer));
}
```

Every call through either endpoint now produces a span.

## Spans

Each span is named `<Service>/<Method>`, with kind `server` (from
`OtelRpcInterceptor`) or `client` (from `OtelRpcClientInterceptor`).

| Attribute | Value |
| --- | --- |
| `rpc.system` | `rpc_dart` |
| `rpc.service` | service name |
| `rpc.method` | method name |
| `rpc.call_type` | `unary`, `server_stream`, `client_stream`, `bidirectional_stream` |
| `rpc.trace_id` | `RpcContext.traceId`, when present (server only) |
| `rpc.grpc.status_code` | numeric gRPC status, `0` = OK (int) |
| `rpc.grpc.status` | status name: `OK`, `UNAVAILABLE`, `DEADLINE_EXCEEDED`, ... |
| `rpc.stream.messages` | response messages emitted (server and bidirectional streams) |

On success the span status is `ok`. On error the exception is recorded and the
status is `error`; the code comes from `RpcStatusException.statusCode`, and any
other error is reported as `UNKNOWN` (2).

A streaming span ends when the response stream completes or its subscriber
cancels. An error event in the middle of a stream does not end it: each error
is recorded on the span, and the last one sets the final status.

### Accessing the span in a handler

`OtelRpcInterceptor` stores the server span in the call's `RpcContext` under
`OtelRpcKeys.span`:

```dart
Future<RpcString> _hello(RpcString request, {RpcContext? context}) async {
  final span = context?.getValue<Span>(OtelRpcKeys.span);
  span?.setAttribute(Attribute.fromString('greeting.name', request.value));
  return RpcString('Hello, ${request.value}');
}
```

The handler also runs with the server span as the ambient OTel context
(`Context.current`), so spans started inside it nest under the RPC span.

## Propagation

- **Server:** extraction is automatic. `OtelRpcInterceptor` calls
  `RpcOtelPropagator.extract` on every incoming call and parents its span on
  the caller's.
- **Client:** `OtelRpcClientInterceptor` injects `traceparent` / `tracestate`
  into every outgoing call.

Without the client interceptor, inject by hand. `inject` uses
`Context.current` unless you pass `context:`, and returns the context unchanged
when there is no active span. `GreeterCaller` is any caller contract whose
method forwards `context:` to `callUnary`:

```dart
Future<RpcString> tracedHello(GreeterCaller greeter, Span parent) {
  final context = RpcOtelPropagator.inject(
    RpcContext.empty(),
    context: contextWithSpan(Context.current, parent),
  );
  return greeter.hello(const RpcString('Ada'), context: context);
}
```

## Metrics

Pass `RpcOtelMetrics` to either interceptor. One instance can be shared by both
sides; each side writes to its own instruments.

```dart
// Meter is part of the opentelemetry package's experimental API.
// ignore: implementation_imports
import 'package:opentelemetry/src/experimental_api.dart' show Meter;

void instrumentWithMetrics(
  RpcResponderEndpoint server,
  RpcCallerEndpoint client,
  Tracer tracer,
  Meter meter,
) {
  final metrics = RpcOtelMetrics(meter: meter);
  server.addInterceptor(OtelRpcInterceptor(tracer: tracer, metrics: metrics));
  client.addInterceptor(
    OtelRpcClientInterceptor(tracer: tracer, metrics: metrics),
  );
}
```

| Instrument | Type | Unit |
| --- | --- | --- |
| `rpc.server.requests` | Counter | `{call}` |
| `rpc.server.duration` | Counter (running sum) | `ms` |
| `rpc.client.requests` | Counter | `{call}` |
| `rpc.client.duration` | Counter (running sum) | `ms` |

Every measurement carries `rpc.system`, `rpc.service`, `rpc.method`,
`rpc.grpc.status_code` (int) and `rpc.grpc.status` (name). Names follow the
[OpenTelemetry RPC semantic conventions](https://opentelemetry.io/docs/specs/semconv/rpc/rpc-metrics/).

Duration is a sum counter, not a histogram: the `opentelemetry` `Meter` offers
only `createCounter`. So the average is available, percentiles are not.

The `opentelemetry` 0.18 SDK's `Counter.add` records nothing, so a `Meter` from
its `MeterProvider` exports no data. Supply a `Meter` implementation backed by
your metrics pipeline.

A failure inside the meter never fails the call; it is recorded as a
`rpc.metrics.record_failed` event on the span.

## Bridging `LogController` into OpenTelemetry

`LogControllerOtelOutput` is a `LogOutput` that mirrors the built-in logger's
spans (`LogScope.startSpan`, `LogScope.withSpan`) and events into OTel:

```dart
LogController buildLogger(Tracer tracer) {
  return LogController(
    outputs: [
      ConsoleOutput(),
      // Inside a handler Context.current is the RPC span, so log spans
      // started there become its children.
      LogControllerOtelOutput(tracer: tracer),
    ],
  );
}
```

| LogController record | OpenTelemetry |
| --- | --- |
| `LogSpanStart` | `tracer.startSpan(name)` with the record's start time; child of the open parent span when `parentSpanId` is set |
| `LogEvent` with a known `spanId` | `span.addEvent(message, attributes)` |
| `LogEvent` without one | zero-duration span `log.<scope>` |
| `LogSpan` (end) | data as attributes, `ok`/`error` status, `span.end(endTime)` |

Nested log spans become child OTel spans. A log span or standalone event with
no open parent is parented on `rootContextProvider()`, which defaults to
`Context.current`. So a `withSpan('db.query', ...)` inside a handler becomes a
child of the server span from `OtelRpcInterceptor`, giving one connected trace
from the caller down to the handler's own work. Pass `rootContextProvider:`
only to choose a different root.

`LogControllerOtelOutput` does not use the OTel logs API. A log line inside an
open log span becomes a span event; one outside any log span becomes its own
zero-duration span. Keep the controller's `minLevel` at `info` or above, or
every debug line becomes a span.

Spans whose end record never arrives are bounded: past `maxOpenSpans` (default
1024) the oldest are ended, and a sweep every `sweepInterval` (default 30 s)
ends any open longer than `spanTtl` (default 5 min). `dispose()` ends whatever
is still open.
