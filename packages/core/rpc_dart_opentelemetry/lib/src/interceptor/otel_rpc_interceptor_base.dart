// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:opentelemetry/api.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/transport.dart' show wireStatusFor;

import '../metrics/rpc_otel_metrics.dart';
import '../metrics/rpc_status_names.dart';

/// One observed call: its span and what the span ends with.
final class OtelRpcCall {
  OtelRpcCall._(
    this.call,
    this.type,
    this.span,
    this.context,
    this.otelContext,
  );

  /// The call.
  final RpcCallInfo call;

  /// The call's shape.
  final RpcMethodType type;

  /// The call's span.
  final Span span;

  /// The context the rest of the chain runs with.
  final RpcContext context;

  /// The ambient OTel context the rest of the chain runs in.
  final Context otelContext;

  int _messages = 0;
  bool _streamErrorRecorded = false;

  bool get _streamsResponse =>
      type == RpcMethodType.serverStream ||
      type == RpcMethodType.bidirectionalStream;
}

/// Shared base for the server and client OpenTelemetry interceptors.
///
/// Built on [RpcCallObserverInterceptor]: it sees every call start and end,
/// for every call shape. Subclasses implement only [startSpan], the single
/// point of difference (the server extracts the W3C parent context and uses
/// [SpanKind.server]; the client injects the context and uses
/// [SpanKind.client]).
///
/// A span ends with status OK when the call succeeds, CANCELLED when it is
/// cancelled (its consumer cancelled the response stream), and the call's
/// error status when it fails. A streamed response records every error on the
/// span and the number of messages as `rpc.stream.messages`.
abstract class OtelRpcInterceptorBase
    extends RpcCallObserverInterceptor<OtelRpcCall> {
  final Tracer tracer;
  final RpcOtelMetrics? metrics;

  const OtelRpcInterceptorBase({required this.tracer, this.metrics});

  /// Which side this interceptor sits on. Determines the metric namespace
  /// (`rpc.server.*` vs `rpc.client.*`) used by [RpcOtelMetrics.recordCall].
  /// Mirrors the [SpanKind] each subclass uses in [startSpan].
  RpcMetricSide get metricSide;

  /// Starts a new span for [call] of the given [type], applies whatever W3C
  /// context propagation the side requires, stores the span in the
  /// [RpcContext] values for downstream access, and returns the span together
  /// with the updated [RpcContext] and the active ambient OTel [Context].
  (Span, RpcContext, Context) startSpan(RpcCallInfo call, RpcMethodType type);

  /// The `rpc.call_type` attribute value for [type].
  static String callTypeAttribute(RpcMethodType type) => switch (type) {
    RpcMethodType.unary => 'unary',
    RpcMethodType.serverStream => 'server_stream',
    RpcMethodType.clientStream => 'client_stream',
    RpcMethodType.bidirectionalStream => 'bidirectional_stream',
  };

  @override
  OtelRpcCall onCallStart(RpcCallInfo call, RpcMethodType type) {
    final (span, context, otelContext) = startSpan(call, type);
    return OtelRpcCall._(call, type, span, context, otelContext);
  }

  @override
  RpcContext contextFor(OtelRpcCall state, RpcContext context) => state.context;

  @override
  Future<T> runCall<T>(OtelRpcCall state, Future<T> Function() body) =>
      _runInContext(state.otelContext, body);

  @override
  void onResponseMessage(OtelRpcCall state) => state._messages++;

  @override
  void onResponseError(OtelRpcCall state, Object error, StackTrace stackTrace) {
    state.span.recordException(error, stackTrace: stackTrace);
    state._streamErrorRecorded = true;
  }

  @override
  void onCallEnd(OtelRpcCall state, RpcCallOutcome outcome, Duration duration) {
    if (state._streamsResponse) {
      state.span.setAttribute(
        Attribute.fromInt('rpc.stream.messages', state._messages),
      );
    }
    switch (outcome) {
      case RpcCallSucceeded():
        _finish(state, duration, status: RpcStatus.ok);
      case RpcCallCancelled():
        _finish(state, duration, status: RpcStatus.cancelled);
      case RpcCallFailed(:final error, :final stackTrace):
        _finishWithError(state, duration, error, stackTrace);
    }
  }

  /// Runs [body] with [otelContext] attached as the ambient OTel context, then
  /// returns its value (or rethrows its error preserving the stack trace).
  ///
  /// The opentelemetry `zone()` helper attaches a `whenComplete` callback to the
  /// run'd future and DISCARDS the derived future; when that future completes
  /// with an error, the error is delivered to the zone unhandled — in a server
  /// it reaches the root zone and kills the isolate, while the awaiting caller
  /// ALSO receives it (double delivery). A thrown [RpcStatusException] is the
  /// normal way a handler returns an error status, so this would crash the
  /// server on every expected error. We therefore catch inside the zone so the
  /// run'd future always completes *successfully* with an [_Outcome], and
  /// re-surface the error outside the zone where it propagates normally.
  Future<T> _runInContext<T>(
    Context otelContext,
    Future<T> Function() body,
  ) async {
    final outcome = await zone(otelContext).run<Future<_Outcome<T>>>(() async {
      try {
        return _Outcome.value(await body());
      } catch (e, st) {
        return _Outcome.error(e, st);
      }
    });
    return outcome.unwrap();
  }

  void _finish(
    OtelRpcCall state,
    Duration duration, {
    required RpcStatus status,
  }) {
    final span = state.span;
    // semconv requires rpc.grpc.status_code as the numeric code (0..16);
    // the human-readable name goes under the non-semconv rpc.grpc.status key.
    span
      ..setAttribute(Attribute.fromInt('rpc.grpc.status_code', status.code))
      ..setAttribute(Attribute.fromString('rpc.grpc.status', status.grpcName));
    if (status == RpcStatus.ok) {
      span.setStatus(StatusCode.ok);
    } else {
      span.setStatus(StatusCode.error, status.grpcName);
    }
    _recordCall(state, duration, status.code);
    span.end();
  }

  void _finishWithError(
    OtelRpcCall state,
    Duration duration,
    Object error,
    StackTrace stackTrace,
  ) {
    final span = state.span;
    // A server records the status its caller receives, which core's
    // translation decides; a client records what reached it.
    final status = metricSide == RpcMetricSide.server
        ? wireStatusFor(error).status
        : rpcStatusCodeFromError(error);
    // A stream's errors are already on the span, recorded as they arrived.
    if (!state._streamErrorRecorded) {
      span.recordException(error, stackTrace: stackTrace);
    }
    span
      ..setAttribute(Attribute.fromInt('rpc.grpc.status_code', status.code))
      ..setAttribute(Attribute.fromString('rpc.grpc.status', status.grpcName))
      ..setStatus(StatusCode.error, error.toString());
    _recordCall(state, duration, status.code);
    span.end();
  }

  void _recordCall(OtelRpcCall state, Duration duration, int statusCode) {
    try {
      metrics?.recordCall(
        state.call,
        statusCode: statusCode,
        duration: duration,
        side: metricSide,
      );
    } catch (e, st) {
      // Best-effort: a misconfigured meter must not break the wrapped RPC call.
      // No logger is reachable here, so surface the failure on the span (which
      // is the diagnostic facility this class owns) instead of dropping it.
      _recordMetricsFailure(state.span, e, st);
    }
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
}

/// Result of running a body inside the OTel ambient context: either a [value]
/// or an [error] with its [stackTrace]. Lets [OtelRpcInterceptorBase._runInContext]
/// carry an error out of the zone as a normal value (see that method for why).
class _Outcome<T> {
  _Outcome.value(this._value) : _error = null, _stackTrace = null;
  _Outcome.error(Object error, StackTrace stackTrace)
    : _value = null,
      _error = error,
      _stackTrace = stackTrace;

  final T? _value;
  final Object? _error;
  final StackTrace? _stackTrace;

  T unwrap() {
    final error = _error;
    if (error != null) Error.throwWithStackTrace(error, _stackTrace!);
    return _value as T;
  }
}
