// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:opentelemetry/api.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../metrics/rpc_otel_metrics.dart';
import '../metrics/rpc_status_names.dart';
import '../propagation/rpc_otel_propagator.dart';

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
class OtelRpcClientInterceptor implements IRpcInterceptor {
  final Tracer _tracer;
  final RpcOtelMetrics? _metrics;

  const OtelRpcClientInterceptor({
    required Tracer tracer,
    RpcOtelMetrics? metrics,
  })  : _tracer = tracer,
        _metrics = metrics;

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

  (Span, RpcContext, Context) _startSpan(
      RpcMiddlewareContext call, String callType) {
    final span = _tracer.startSpan(
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

  void _finish(
    Span span,
    RpcMiddlewareContext call,
    Stopwatch stopwatch, {
    required int statusCode,
  }) {
    stopwatch.stop();
    final statusName = rpcGrpcStatusName(statusCode);
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

  Stream<T> _wrapWithSpan<T>(
    Stream<T> source,
    Span span,
    RpcMiddlewareContext call,
    Stopwatch stopwatch,
  ) {
    var messageCount = 0;
    var finished = false;

    void finishOnce(
        {required bool isError, Object? error, StackTrace? stackTrace}) {
      if (finished) return;
      finished = true;
      span.setAttribute(Attribute.fromInt('rpc.stream.messages', messageCount));
      if (isError && error != null) {
        _finishWithError(span, call, stopwatch, error, stackTrace!);
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
            finishOnce(isError: true, error: error, stackTrace: st);
            controller.addError(error, st);
          },
          onDone: () {
            finishOnce(isError: false);
            controller.close();
          },
          cancelOnError: false,
        );
      },
      onCancel: () {
        finishOnce(isError: false);
        return subscription.cancel();
      },
    );

    return controller.stream;
  }
}