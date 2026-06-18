// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:opentelemetry/api.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../propagation/rpc_otel_propagator.dart';
import 'otel_rpc_interceptor_base.dart';

/// Context key used to retrieve the active [Span] from [RpcContext.getValue].
///
/// Business-layer code can access the current span to add custom attributes:
/// ```dart
/// final span = context.getValue(OtelRpcKeys.span) as Span?;
/// span?.setAttribute(Attribute.fromString('user.id', userId));
/// ```
abstract final class OtelRpcKeys {
  static const span = #otel_rpc_span;
}

/// OpenTelemetry interceptor for rpc_dart.
///
/// Wraps every RPC call in an OTel span, propagates W3C trace context through
/// [RpcContext] headers, and optionally records call metrics.
///
/// Setup:
/// ```dart
/// final tracer = globalTracerProvider.getTracer('my-service');
///
/// final endpoint = MyResponderEndpoint(transport: ...)
///   ..addInterceptor(OtelRpcInterceptor(tracer: tracer));
/// ```
///
/// With metrics:
/// ```dart
/// final meter = globalMeterProvider.getMeter('my-service');
/// endpoint.addInterceptor(OtelRpcInterceptor(
///   tracer: tracer,
///   metrics: RpcOtelMetrics(meter: meter),
/// ));
/// ```
class OtelRpcInterceptor extends OtelRpcInterceptorBase {
  const OtelRpcInterceptor({
    required super.tracer,
    super.metrics,
  });

  /// Starts a new span, extracts W3C parent context from [RpcContext] headers,
  /// and stores the span in [RpcContext] values for downstream access.
  @override
  (Span, RpcContext, Context) startSpan(
      RpcMiddlewareContext call, String callType) {
    final parentContext = RpcOtelPropagator.extract(call.context);

    final attributes = [
      Attribute.fromString('rpc.system', 'rpc_dart'),
      Attribute.fromString('rpc.service', call.serviceName),
      Attribute.fromString('rpc.method', call.methodName),
      Attribute.fromString('rpc.call_type', callType),
      if (call.context.traceId != null)
        Attribute.fromString('rpc.trace_id', call.context.traceId!),
    ];

    final span = tracer.startSpan(
      '${call.serviceName}/${call.methodName}',
      context: parentContext,
      kind: SpanKind.server,
      attributes: attributes,
    );

    final updatedContext = call.context.withValue(OtelRpcKeys.span, span);
    call.updateContext(updatedContext);

    // Make the span the active ambient OTel context for the downstream call,
    // so spans/log-spans created inside the handler nest under the RPC span.
    final otelContext = contextWithSpan(parentContext, span);

    return (span, updatedContext, otelContext);
  }
}
