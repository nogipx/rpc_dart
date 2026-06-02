// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:fixnum/fixnum.dart';
import 'package:opentelemetry/api.dart' hide SpanStatus;
import 'package:rpc_dart/rpc_dart.dart';

/// A [LogOutput] that mirrors [LogController] spans and events into
/// OpenTelemetry.
///
/// Each [LogSpanStart] opens an OTel [Span] with the same start timestamp.
/// Each [LogEvent] carrying a `spanId` becomes `span.addEvent(...)`.
/// Each [LogSpan] (end record) finishes the OTel span with the recorded
/// status, attributes, and end timestamp.
///
/// Parent linkage is preserved: when a [LogSpanStart] carries
/// `parentSpanId`, the OTel span is created as a child of the previously
/// opened parent span. This lets a `LogScope.withSpan(...)` block nest
/// underneath the server-side RPC span produced by [OtelRpcInterceptor]
/// when [rootContextProvider] is wired to that span.
///
/// Usage:
/// ```dart
/// final tracer = globalTracerProvider.getTracer('my-service');
/// final logController = LogController(outputs: [
///   ConsoleOutput(),
///   LogControllerOtelOutput(tracer: tracer),
/// ]);
/// ```
///
/// To nest log-spans under the active RPC span, supply
/// [rootContextProvider] (called for every record without a known parent):
///
/// ```dart
/// LogControllerOtelOutput(
///   tracer: tracer,
///   rootContextProvider: () => Context.current,
/// )
/// ```
///
/// Standalone [LogEvent]s (no `spanId`) emit a single-shot span named
/// `log.<scope>` so they remain visible in OTel without polluting the
/// `addEvent` API.
class LogControllerOtelOutput extends LogOutput {
  final Tracer _tracer;
  final Context Function()? _rootContextProvider;
  final Map<String, Span> _open = <String, Span>{};

  LogControllerOtelOutput({
    required Tracer tracer,
    Context Function()? rootContextProvider,
  })  : _tracer = tracer,
        _rootContextProvider = rootContextProvider;

  @override
  bool get isAsync => false;

  @override
  void write(LogRecord record) {
    switch (record) {
      case LogSpanStart():
        _onStart(record);
      case LogEvent():
        _onEvent(record);
      case LogSpan():
        _onEnd(record);
    }
  }

  @override
  void dispose() {
    for (final span in _open.values) {
      try {
        span.end();
      } catch (_) {}
    }
    _open.clear();
  }

  // ---------------------------------------------------------------------------

  void _onStart(LogSpanStart record) {
    final parent = record.parentSpanId != null ? _open[record.parentSpanId] : null;
    final parentContext = parent != null
        ? contextWithSpan(_rootContextProvider?.call() ?? Context.current, parent)
        : (_rootContextProvider?.call() ?? Context.current);

    final span = _tracer.startSpan(
      record.name,
      context: parentContext,
      kind: SpanKind.internal,
      startTime: _toInt64(record.timestamp),
      attributes: [
        Attribute.fromString('log.scope', record.scope),
        if (record.traceId != null)
          Attribute.fromString('log.trace_id', record.traceId!),
      ],
    );

    _open[record.spanId] = span;
  }

  void _onEvent(LogEvent record) {
    final spanId = record.spanId;
    if (spanId != null) {
      final span = _open[spanId];
      if (span != null) {
        span.addEvent(
          record.message,
          attributes: _eventAttributes(record),
        );
        return;
      }
    }
    // Standalone event — emit a zero-duration span so it stays visible.
    final oneShot = _tracer.startSpan(
      'log.${record.scope}',
      context: _rootContextProvider?.call() ?? Context.current,
      kind: SpanKind.internal,
      startTime: _toInt64(record.timestamp),
      attributes: _eventAttributes(record),
    );
    oneShot.end(endTime: _toInt64(record.timestamp));
  }

  void _onEnd(LogSpan record) {
    final span = _open.remove(record.spanId);
    if (span == null) return; // start was never seen (or already closed).

    if (record.data != null) {
      for (final entry in record.data!.entries) {
        span.setAttribute(_attribute(entry.key, entry.value));
      }
    }
    if (record.status == SpanStatus.error) {
      if (record.error != null) {
        span.recordException(
          record.error!,
          stackTrace: record.stackTrace ?? StackTrace.empty,
        );
      }
      span.setStatus(StatusCode.error, record.error?.toString() ?? 'error');
    } else {
      span.setStatus(StatusCode.ok);
    }
    span.end(endTime: _toInt64(record.endTime));
  }

  // ---------------------------------------------------------------------------

  List<Attribute> _eventAttributes(LogEvent record) {
    return [
      Attribute.fromString('log.level', record.level.name),
      Attribute.fromString('log.scope', record.scope),
      if (record.tag != null) Attribute.fromString('log.tag', record.tag!),
      if (record.error != null)
        Attribute.fromString('exception.message', record.error.toString()),
      if (record.stackTrace != null)
        Attribute.fromString('exception.stacktrace', record.stackTrace.toString()),
      if (record.traceId != null)
        Attribute.fromString('log.trace_id', record.traceId!),
      if (record.requestId != null)
        Attribute.fromString('log.request_id', record.requestId!),
      if (record.data != null)
        for (final entry in record.data!.entries) _attribute(entry.key, entry.value),
    ];
  }

  Attribute _attribute(String key, Object value) {
    if (value is int) return Attribute.fromInt(key, value);
    if (value is double) return Attribute.fromDouble(key, value);
    if (value is bool) return Attribute.fromBoolean(key, value);
    return Attribute.fromString(key, value.toString());
  }

  Int64 _toInt64(DateTime t) {
    // OTel SDK expects nanoseconds since epoch.
    return Int64(t.microsecondsSinceEpoch) * 1000;
  }
}