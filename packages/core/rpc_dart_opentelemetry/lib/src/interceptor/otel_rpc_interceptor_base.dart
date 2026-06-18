// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:opentelemetry/api.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../metrics/rpc_otel_metrics.dart';
import '../metrics/rpc_status_names.dart';

/// Shared base for the server and client OpenTelemetry interceptors.
///
/// Holds the common fields ([_tracer], [_metrics]) and contains the full
/// `intercept*` flow plus the span finishing/stream-wrapping helpers, which are
/// identical for both sides. Subclasses implement only [startSpan], which is the
/// single point of difference (server extracts the W3C parent context and uses
/// [SpanKind.server]; client injects the context and uses [SpanKind.client]).
abstract class OtelRpcInterceptorBase implements IRpcInterceptor {
  final Tracer tracer;
  final RpcOtelMetrics? metrics;

  const OtelRpcInterceptorBase({required this.tracer, this.metrics});

  /// Which side this interceptor sits on. Determines the metric namespace
  /// (`rpc.server.*` vs `rpc.client.*`) used by [recordCall]. Mirrors the
  /// [SpanKind] each subclass uses in [startSpan].
  RpcMetricSide get metricSide;

  /// Starts a new span for [call] of the given [callType], applies whatever
  /// W3C context propagation the side requires, stores the span in the
  /// [RpcContext] values for downstream access, and returns the span together
  /// with the updated [RpcContext] and the active ambient OTel [Context].
  (Span, RpcContext, Context) startSpan(
    RpcMiddlewareContext call,
    String callType,
  );

  // ---------------------------------------------------------------------------
  // Unary
  // ---------------------------------------------------------------------------

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    final (span, context, otelContext) = startSpan(call, 'unary');
    final stopwatch = Stopwatch()..start();
    try {
      final response = await zone(
        otelContext,
      ).run(() async => await next(context, request));
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
    final (span, context, otelContext) = startSpan(call, 'server_stream');
    final stopwatch = Stopwatch()..start();
    try {
      final stream = await zone(
        otelContext,
      ).run(() async => await next(context, request));
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
    final (span, context, otelContext) = startSpan(call, 'client_stream');
    final stopwatch = Stopwatch()..start();
    try {
      final response = await zone(
        otelContext,
      ).run(() async => await next(context, requests));
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
    final (span, context, otelContext) = startSpan(
      call,
      'bidirectional_stream',
    );
    final stopwatch = Stopwatch()..start();
    try {
      final stream = await zone(
        otelContext,
      ).run(() async => await next(context, requests));
      return _wrapWithSpan(stream, span, call, stopwatch);
    } catch (e, st) {
      _finishWithError(span, call, stopwatch, e, st);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

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
      metrics?.recordCall(
        call,
        statusCode: statusCode,
        duration: stopwatch.elapsed,
        side: metricSide,
      );
    } catch (e, st) {
      // Best-effort: a misconfigured meter must not break the wrapped RPC call.
      // No logger is reachable here, so surface the failure on the span (which
      // is the diagnostic facility this class owns) instead of dropping it.
      _recordMetricsFailure(span, e, st);
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
    final statusCode = rpcStatusCodeFromError(error);
    final statusName = rpcGrpcStatusName(statusCode);
    span
      ..recordException(error, stackTrace: stackTrace)
      ..setAttribute(Attribute.fromInt('rpc.grpc.status_code', statusCode))
      ..setAttribute(Attribute.fromString('rpc.grpc.status', statusName))
      ..setStatus(StatusCode.error, error.toString());
    try {
      metrics?.recordCall(
        call,
        statusCode: statusCode,
        duration: stopwatch.elapsed,
        side: metricSide,
      );
    } catch (e, st) {
      // Best-effort: a misconfigured meter must not break the wrapped RPC call.
      _recordMetricsFailure(span, e, st);
    }
    span.end();
  }

  /// Surfaces a best-effort `metrics.recordCall` failure on the active [span]
  /// as a debug-level event so a misconfigured meter is visible instead of
  /// being swallowed silently. The exception is deliberately NOT rethrown:
  /// telemetry must never break the wrapped RPC call.
  void _recordMetricsFailure(Span span, Object error, StackTrace stackTrace) {
    span.addEvent(
      'rpc.metrics.record_failed',
      attributes: [
        Attribute.fromString('log.level', 'debug'),
        Attribute.fromString('exception.message', error.toString()),
        Attribute.fromString('exception.stacktrace', stackTrace.toString()),
      ],
    );
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
          span,
          call,
          stopwatch,
          lastError!,
          lastStackTrace ?? StackTrace.empty,
        );
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
