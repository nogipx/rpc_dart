// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:opentelemetry/api.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../metrics/rpc_otel_metrics.dart';
import '../metrics/rpc_status_names.dart';
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
    final (span, context, otelContext) = _startSpan(call, 'unary');
    final stopwatch = Stopwatch()..start();
    try {
      final response = await zone(otelContext).run(
        () async => await next(context, request),
      );
      _finish(span, call, stopwatch, statusCode: RpcStatus.ok);
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
    final (span, context, otelContext) = _startSpan(call, 'server_stream');
    final stopwatch = Stopwatch()..start();
    try {
      final stream = await zone(otelContext).run(
        () async => await next(context, request),
      );
      return _wrapWithSpan(stream, span, call, stopwatch);
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
    final (span, context, otelContext) = _startSpan(call, 'client_stream');
    final stopwatch = Stopwatch()..start();
    try {
      final response = await zone(otelContext).run(
        () async => await next(context, requests),
      );
      _finish(span, call, stopwatch, statusCode: RpcStatus.ok);
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
    final (span, context, otelContext) = _startSpan(call, 'bidirectional_stream');
    final stopwatch = Stopwatch()..start();
    try {
      final stream = await zone(otelContext).run(
        () async => await next(context, requests),
      );
      return _wrapWithSpan(stream, span, call, stopwatch);
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
  (Span, RpcContext, Context) _startSpan(
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

    final span = _tracer.startSpan(
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

  void _finish(
    Span span,
    RpcMiddlewareContext call,
    Stopwatch stopwatch, {
    required int statusCode,
  }) {
    stopwatch.stop();
    final statusName = rpcGrpcStatusName(statusCode);
    // semconv requires rpc.grpc.status_code as the numeric code (0..16);
    // the human-readable name goes under the non-semconv rpc.grpc.status key.
    span
      ..setAttribute(Attribute.fromInt('rpc.grpc.status_code', statusCode))
      ..setAttribute(Attribute.fromString('rpc.grpc.status', statusName));
    if (statusCode == RpcStatus.ok) {
      span.setStatus(StatusCode.ok);
    } else {
      span.setStatus(StatusCode.error, statusName);
    }
    try {
      _metrics?.recordCall(
        call,
        statusCode: statusCode,
        duration: stopwatch.elapsed,
      );
    } catch (_) {}
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
    final statusCode = rpcStatusCodeFromError(error);
    final statusName = rpcGrpcStatusName(statusCode);
    span
      ..recordException(error, stackTrace: stackTrace)
      ..setAttribute(Attribute.fromInt('rpc.grpc.status_code', statusCode))
      ..setAttribute(Attribute.fromString('rpc.grpc.status', statusName))
      ..setStatus(StatusCode.error, error.toString());
    try {
      _metrics?.recordCall(
        call,
        statusCode: statusCode,
        duration: stopwatch.elapsed,
      );
    } catch (_) {}
    span.end();
  }

  /// Wraps a response stream in a span: ends the span when the stream
  /// terminates (completes, is cancelled, or errors fatally). Counts messages
  /// and records the total as a span attribute on completion.
  ///
  /// The source is listened with `cancelOnError: false`, so an `onError` event
  /// is NOT terminal: a server/bidi stream may emit a non-fatal item error and
  /// then keep going (or complete normally). The span therefore must end on
  /// stream TERMINATION (onDone / onCancel), not on the first error. Each error
  /// is recorded on the span as it arrives, and the *last* one determines the
  /// final error status; the span still ends exactly once.
  ///
  /// Uses [StreamController] with an [onCancel] hook instead of
  /// [StreamTransformer.fromHandlers] because the latter has no cancel callback,
  /// which would leave spans open forever when consumers unsubscribe early.
  Stream<T> _wrapWithSpan<T>(
    Stream<T> source,
    Span span,
    RpcMiddlewareContext call,
    Stopwatch stopwatch,
  ) {
    var messageCount = 0;
    var finished = false;
    Object? lastError;
    StackTrace? lastStackTrace;

    void finishOnce() {
      if (finished) return;
      finished = true;
      span.setAttribute(Attribute.fromInt('rpc.stream.messages', messageCount));
      if (lastError != null) {
        _finishWithError(
            span, call, stopwatch, lastError!, lastStackTrace ?? StackTrace.empty);
      } else {
        _finish(span, call, stopwatch, statusCode: RpcStatus.ok);
      }
    }

    late StreamController<T> controller;
    late StreamSubscription<T> subscription;

    controller = StreamController<T>(
      onListen: () {
        subscription = source.listen(
          (data) {
            messageCount++;
            controller.add(data);
          },
          onError: (Object error, StackTrace st) {
            // Non-terminal under cancelOnError:false. Record the error on the
            // span but keep it open — the stream may still complete normally.
            // The span ends on termination (onDone / onCancel).
            span.recordException(error, stackTrace: st);
            lastError = error;
            lastStackTrace = st;
            controller.addError(error, st);
          },
          onDone: () {
            finishOnce();
            controller.close();
          },
          cancelOnError: false,
        );
      },
      onCancel: () {
        finishOnce();
        return subscription.cancel();
      },
    );

    return controller.stream;
  }
}
