// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:opentelemetry/api.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../metrics/rpc_otel_metrics.dart';
import '../propagation/rpc_otel_propagator.dart';

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
class OtelRpcInterceptor implements IRpcInterceptor {
  final Tracer _tracer;
  final RpcOtelMetrics? _metrics;

  const OtelRpcInterceptor({
    required Tracer tracer,
    RpcOtelMetrics? metrics,
  })  : _tracer = tracer,
        _metrics = metrics;

  // ---------------------------------------------------------------------------
  // Unary
  // ---------------------------------------------------------------------------

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    final (span, context) = _startSpan(call, 'unary');
    final stopwatch = Stopwatch()..start();
    try {
      final response = await next(context, request);
      _finish(span, call, stopwatch, error: false);
      return response;
    } catch (e, st) {
      _finishWithError(span, call, stopwatch, e, st);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Server stream
  // ---------------------------------------------------------------------------

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    final (span, context) = _startSpan(call, 'server_stream');
    final stopwatch = Stopwatch()..start();
    try {
      final stream = await next(context, request);
      return stream.transform(_spanStreamTransformer(span, call, stopwatch));
    } catch (e, st) {
      _finishWithError(span, call, stopwatch, e, st);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Client stream
  // ---------------------------------------------------------------------------

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    final (span, context) = _startSpan(call, 'client_stream');
    final stopwatch = Stopwatch()..start();
    try {
      final response = await next(context, requests);
      _finish(span, call, stopwatch, error: false);
      return response;
    } catch (e, st) {
      _finishWithError(span, call, stopwatch, e, st);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Bidirectional stream
  // ---------------------------------------------------------------------------

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    final (span, context) = _startSpan(call, 'bidirectional_stream');
    final stopwatch = Stopwatch()..start();
    try {
      final stream = await next(context, requests);
      return stream.transform(_spanStreamTransformer(span, call, stopwatch));
    } catch (e, st) {
      _finishWithError(span, call, stopwatch, e, st);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Starts a new span, extracts W3C parent context from [RpcContext] headers,
  /// and stores the span in [RpcContext] values for downstream access.
  (Span, RpcContext) _startSpan(RpcMiddlewareContext call, String callType) {
    final parentContext = RpcOtelPropagator.extract(call.context);

    final attributes = [
      Attribute.fromString('rpc.system', 'rpc_dart'),
      Attribute.fromString('rpc.service', call.serviceName),
      Attribute.fromString('rpc.method', call.methodName),
      Attribute.fromString('rpc.call_type', callType),
      if (call.context.traceId != null)
        Attribute.fromString('rpc.trace_id', call.context.traceId!),
    ];

    final span = _tracer.startSpan(
      '${call.serviceName}/${call.methodName}',
      context: parentContext,
      kind: SpanKind.server,
      attributes: attributes,
    );

    final updatedContext = call.context.withValue(OtelRpcKeys.span, span);
    call.updateContext(updatedContext);

    return (span, updatedContext);
  }

  void _finish(
    Span span,
    RpcMiddlewareContext call,
    Stopwatch stopwatch, {
    required bool error,
  }) {
    stopwatch.stop();
    if (!error) {
      span.setStatus(StatusCode.ok);
      _metrics?.recordCall(call, stopwatch.elapsed);
    }
    span.end();
  }

  void _finishWithError(
    Span span,
    RpcMiddlewareContext call,
    Stopwatch stopwatch,
    Object error,
    StackTrace stackTrace,
  ) {
    stopwatch.stop();
    span
      ..recordException(error, stackTrace: stackTrace)
      ..setStatus(StatusCode.error, error.toString());
    _metrics?.recordError(call, stopwatch.elapsed);
    span.end();
  }

  /// Wraps a response stream: ends the span after the stream completes or errors.
  /// Counts messages and records the total as a span attribute on completion.
  StreamTransformer<T, T> _spanStreamTransformer<T>(
    Span span,
    RpcMiddlewareContext call,
    Stopwatch stopwatch,
  ) {
    var messageCount = 0;
    return StreamTransformer.fromHandlers(
      handleData: (data, sink) {
        messageCount++;
        sink.add(data);
      },
      handleError: (error, stackTrace, sink) {
        span.setAttribute(Attribute.fromInt('rpc.stream.messages', messageCount));
        _finishWithError(span, call, stopwatch, error, stackTrace);
        sink.addError(error, stackTrace);
      },
      handleDone: (sink) {
        span.setAttribute(Attribute.fromInt('rpc.stream.messages', messageCount));
        _finish(span, call, stopwatch, error: false);
        sink.close();
      },
    );
  }
}
