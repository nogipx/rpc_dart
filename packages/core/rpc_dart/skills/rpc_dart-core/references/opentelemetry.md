<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# OpenTelemetry

`rpc_dart_opentelemetry` adds OpenTelemetry tracing and call metrics to
rpc_dart endpoints, and mirrors `LogController` spans and events into OTel. It
is built on the [`opentelemetry`](https://pub.dev/packages/opentelemetry)
package (Workiva, 0.18). Use it when calls must show up as spans in a tracing
backend (Jaeger, Tempo, an OTLP collector) and one trace must cross service
boundaries. For plain logging see `logging-and-health.md`; to stream logs to a
dev machine see `remote-logging.md`.

## Setup

```yaml
dependencies:
  rpc_dart: ^6.3.0
  rpc_dart_opentelemetry: ^0.4.0
  opentelemetry: ^0.18.0
```

Pure Dart, no `dart:io`: it also runs on the web.

## Rules

- Instrumentation is two interceptors, added with `endpoint.addInterceptor`:
  `OtelRpcInterceptor` on the `RpcResponderEndpoint` (server spans) and
  `OtelRpcClientInterceptor` on the `RpcCallerEndpoint` (client spans). There
  is no constructor parameter for them. For an `RpcPeerEndpoint` pick the one
  matching the role you want traced.
- Both take `tracer:` (required, an OTel `Tracer`) and `metrics:`
  (`RpcOtelMetrics?`). Both have `const` constructors.
- Install the client interceptor on every caller whose calls should continue
  the trace. It injects W3C `traceparent` / `tracestate` into the call's
  metadata. The server interceptor extracts them and parents its span on the
  caller's span. No other wiring is needed.
- Register the global provider once per process
  (`registerGlobalTracerProvider`), and call `provider.shutdown()` before exit
  so buffered spans are exported.
- Span name is `<Service>/<method>`. Attributes: `rpc.system` (`rpc_dart`),
  `rpc.service`, `rpc.method`, `rpc.call_type` (`unary`, `server_stream`,
  `client_stream`, `bidirectional_stream`), `rpc.grpc.status_code` (int, `0`
  is OK), `rpc.grpc.status` (name). Server spans also carry `rpc.trace_id`.
- A failed call records the exception and sets status `error`. The code comes
  from `RpcStatusException.statusCode`; any other error is `UNKNOWN` (2).
- A streaming span ends when the response stream completes or is cancelled.

## Trace id vs. RpcContext.traceId

They are two different ids, sent side by side.

- `RpcContext.traceId` is rpc_dart's own correlation id. It travels as
  `x-trace-id` and is what `LogScope` records carry (`context-and-metadata.md`).
- The OTel trace id travels in `traceparent` and is what the tracing backend
  shows.

The server interceptor copies `RpcContext.traceId` onto the span as the
`rpc.trace_id` attribute, and `LogControllerOtelOutput` copies a log
record's trace id as `log.trace_id`. Search for those attributes to jump from
a log line to its trace. Nothing converts one id into the other.

## Example

```dart
import 'package:opentelemetry/api.dart';
import 'package:opentelemetry/sdk.dart';
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';

/// [otlpTraces] is an OTLP/HTTP endpoint such as
/// `http://localhost:4318/v1/traces`. Without it spans go to stdout.
TracerProviderBase bootstrapTracing({Uri? otlpTraces}) {
  final provider = TracerProviderBase(
    processors: [
      if (otlpTraces == null)
        SimpleSpanProcessor(ConsoleExporter())
      else
        BatchSpanProcessor(CollectorExporter(otlpTraces)),
    ],
  );
  registerGlobalTracerProvider(provider);
  return provider;
}

final class GreeterResponder extends RpcResponderContract {
  GreeterResponder() : super('Greeter');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'hello',
      handler: _hello,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _hello(RpcString request, {RpcContext? context}) async {
    // The server span of this call.
    final span = context?.getValue<Span>(OtelRpcKeys.span);
    span?.setAttribute(Attribute.fromString('greeting.name', request.value));
    return RpcString('Hello, ${request.value}');
  }
}

final class GreeterCaller extends RpcCallerContract {
  GreeterCaller(RpcCallerEndpoint endpoint) : super('Greeter', endpoint);

  Future<RpcString> hello(RpcString request, {RpcContext? context}) =>
      callUnary<RpcString, RpcString>(
        methodName: 'hello',
        request: request,
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        context: context,
      );
}

Future<void> main() async {
  final provider = bootstrapTracing();
  final tracer = globalTracerProvider.getTracer('greeter', version: '1.0.0');

  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();
  final responder = RpcResponderEndpoint(transport: serverTransport)
    ..addInterceptor(OtelRpcInterceptor(tracer: tracer))
    ..registerServiceContract(GreeterResponder())
    ..start();
  final caller = RpcCallerEndpoint(transport: clientTransport)
    ..addInterceptor(OtelRpcClientInterceptor(tracer: tracer));

  // One trace: client span Greeter/hello -> server span Greeter/hello.
  await GreeterCaller(caller).hello(const RpcString('Ada'));

  await caller.close();
  await responder.close();
  provider.shutdown();
}
```

The handler runs inside the server span's OTel context, so `Context.current`
there is the RPC span, and spans started in the handler nest under it.

## Propagation by hand

Use `RpcOtelPropagator` when a caller has no client interceptor, or when you
need the headers yourself.

- `RpcOtelPropagator.inject(rpcContext, {Context? context})` returns a new
  `RpcContext` with `traceparent` (and `tracestate`) added. It uses
  `Context.current` when `context:` is omitted, and returns `rpcContext`
  unchanged when there is no active span.
- `RpcOtelPropagator.extract(rpcContext)` returns the OTel `Context` restored
  from the incoming headers, or `Context.current` if there is no `traceparent`.

```dart
Future<RpcString> helloUnderSpan(GreeterCaller greeter, Tracer tracer) async {
  final span = tracer.startSpan('checkout');
  try {
    final context = RpcOtelPropagator.inject(
      RpcContext.empty(),
      context: contextWithSpan(Context.current, span),
    );
    return await greeter.hello(const RpcString('Ada'), context: context);
  } finally {
    span.end();
  }
}
```

With `OtelRpcClientInterceptor` installed, the client span's parent is
`Context.current` at the moment of the call. To nest it under your own span,
make the call inside `zone(contextWithSpan(Context.current, span)).run(...)`.

## Metrics

`RpcOtelMetrics({required Meter meter})` creates four counters:
`rpc.server.requests`, `rpc.server.duration`, `rpc.client.requests`,
`rpc.client.duration` (durations are a running sum in `ms`, not a histogram).
Every measurement carries `rpc.system`, `rpc.service`, `rpc.method`,
`rpc.grpc.status_code` and `rpc.grpc.status`. One instance can be shared by
both interceptors; each side writes its own instruments.

```dart
void instrumentWithMetrics(
  RpcResponderEndpoint server,
  RpcCallerEndpoint client,
  Tracer tracer,
  RpcOtelMetrics metrics,
) {
  server.addInterceptor(OtelRpcInterceptor(tracer: tracer, metrics: metrics));
  client.addInterceptor(
    OtelRpcClientInterceptor(tracer: tracer, metrics: metrics),
  );
}
```

`Meter` is not in `package:opentelemetry/api.dart`. Import it from
`package:opentelemetry/src/experimental_api.dart` with
`// ignore: implementation_imports`. A metrics failure never fails the call; it
becomes a `rpc.metrics.record_failed` event on the span.

## Bridging LogController

`LogControllerOtelOutput` is a `LogOutput`. Add it to the `LogController`
outputs (`logging-and-health.md`). Constructor: `tracer:` (required),
`rootContextProvider:` (`Context Function()?`), `maxOpenSpans:` (1024),
`spanTtl:` (5 min), `sweepInterval:` (30 s).

| `LogController` record | OpenTelemetry |
| --- | --- |
| `LogSpanStart` | a new span; child of its parent log span when `parentSpanId` is set |
| `LogEvent` inside an open log span | `span.addEvent(message, attributes)` |
| `LogEvent` outside any span | a zero-duration span named `log.<scope>` |
| `LogSpan` (end) | data as attributes, `ok`/`error` status, span ended |

```dart
LogController buildTracedLogger(Tracer tracer) => LogController(
  minLevel: RpcLogLevel.info,
  outputs: [
    ConsoleOutput(format: ConsoleFormat.compact),
    // Inside a handler Context.current is the RPC span, so a
    // LogScope.withSpan block there becomes its child.
    LogControllerOtelOutput(tracer: tracer),
  ],
);
```

Call `controller.dispose()` at shutdown. It disposes this output, which ends
every span still open.

## Pitfalls

- `OtelRpcKeys.span` is a `Symbol` key. Read it with
  `context?.getValue<Span>(OtelRpcKeys.span)`. It is set only on the
  responder side; on the caller side it is `null`.
- Only the server interceptor without the client one gives disconnected
  traces: every server span becomes a root.
- `CollectorExporter` speaks OTLP over HTTP with protobuf. Point it at the
  collector's HTTP port and path (`:4318/v1/traces`), not the gRPC port 4317.
- `registerGlobalTracerProvider` throws `StateError` on a second call. A
  tracer taken from `globalTracerProvider` before registration is a no-op
  tracer and records nothing. In tests build a `TracerProviderBase` and call
  `getTracer` on it directly.
- The `opentelemetry` 0.18 SDK `MeterProvider` returns counters whose `add`
  records nothing. `RpcOtelMetrics` on that meter exports no data; supply a
  `Meter` implementation backed by your metrics pipeline.
- `rootContextProvider` defaults to `Context.current`, so log spans nest
  under the RPC span either way. Pass a provider only to choose another root.
- Every `LogEvent` outside a log span becomes its own span. With
  `minLevel: debug` that is a span per debug line. Keep `minLevel` at `info`
  or above on a controller that has this output.
- `LogControllerOtelOutput` does not use the OTel logs API. Logs reach the
  backend as spans and span events.
- `SpanStatus` exists in both `package:rpc_dart` (log spans) and
  `package:opentelemetry/api.dart`. Using it unprefixed with both imported is
  an ambiguous-import error; prefix one import.

The full reference is the package README (`rpc_dart_opentelemetry`).
