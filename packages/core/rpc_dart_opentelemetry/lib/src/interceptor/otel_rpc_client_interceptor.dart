// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:opentelemetry/api.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../propagation/rpc_otel_propagator.dart';
import 'otel_rpc_interceptor_base.dart';

/// OpenTelemetry interceptor for the **client** side of rpc_dart.
///
/// Each outgoing call gets:
/// - A [SpanKind.client] span linked to the currently active OTel context,
///   so cross-service traces stitch together with the server-side span
///   created by [OtelRpcInterceptor].
/// - W3C `traceparent` / `tracestate` headers injected into the outgoing
///   [RpcContext] via [RpcOtelPropagator.inject].
/// - Status code + duration recorded into [RpcOtelMetrics] if supplied.
///
/// Setup:
/// ```dart
/// final tracer = globalTracerProvider.getTracer('my-client');
/// final endpoint = MyCallerEndpoint(transport: ...)
///   ..addInterceptor(OtelRpcClientInterceptor(tracer: tracer));
/// ```
class OtelRpcClientInterceptor extends OtelRpcInterceptorBase {
  const OtelRpcClientInterceptor({
    required super.tracer,
    super.metrics,
  });

  @override
  (Span, RpcContext, Context) startSpan(
      RpcMiddlewareContext call, String callType) {
    final span = tracer.startSpan(
      '${call.serviceName}/${call.methodName}',
      kind: SpanKind.client,
      attributes: [
        Attribute.fromString('rpc.system', 'rpc_dart'),
        Attribute.fromString('rpc.service', call.serviceName),
        Attribute.fromString('rpc.method', call.methodName),
        Attribute.fromString('rpc.call_type', callType),
      ],
    );

    final otelContext = contextWithSpan(Context.current, span);
    final injected = RpcOtelPropagator.inject(
      call.context,
      context: otelContext,
    );
    call.updateContext(injected);
    return (span, injected, otelContext);
  }
}
