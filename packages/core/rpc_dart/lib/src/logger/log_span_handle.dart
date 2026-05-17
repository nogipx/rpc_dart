// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:math';

import 'log_level.dart';
import 'log_record.dart';

/// Callback for when a span ends and should be emitted.
typedef SpanCompleteCallback = void Function(LogSpan span);

/// Callback for emitting live events from within a span.
typedef SpanEventCallback = void Function(LogEvent event);

/// Callback for emitting span start.
typedef SpanStartCallback = void Function(LogSpanStart start);

/// Handle to an active (in-progress) span.
///
/// Created by [LogScope.startSpan]. Must be ended explicitly via [end]
/// or automatically via [LogScope.withSpan].
class LogSpanHandle {
  /// Unique span identifier.
  final String spanId;

  /// Operation name.
  final String name;

  /// Scope this span belongs to.
  final String scope;

  /// Parent span ID (for nested spans).
  final String? parentSpanId;

  /// Trace ID for distributed tracing.
  final String? traceId;

  final DateTime _startTime;
  final SpanCompleteCallback _onComplete;
  final SpanEventCallback _onEvent;
  final SpanStartCallback _onStart;
  final List<LogEvent> _events = [];
  Map<String, Object>? _data;
  bool _ended = false;

  /// Creates a [LogSpanHandle] and immediately emits a [LogSpanStart].
  LogSpanHandle({
    required this.name,
    required this.scope,
    required SpanCompleteCallback onComplete,
    required SpanEventCallback onEvent,
    required SpanStartCallback onStart,
    this.parentSpanId,
    this.traceId,
    Map<String, Object>? data,
  })  : spanId = _generateSpanId(),
        _startTime = DateTime.now(),
        _onComplete = onComplete,
        _onEvent = onEvent,
        _onStart = onStart,
        _data = data {
    onStart(LogSpanStart(spanId: spanId, scope: scope, name: name));
  }

  /// Whether this span has been ended.
  bool get isEnded => _ended;

  /// Add an event inside this span.
  void event(
    String message, {
    RpcLogLevel level = RpcLogLevel.info,
    Map<String, Object>? data,
  }) {
    if (_ended) return;
    final logEvent = LogEvent(
      scope: scope,
      level: level,
      message: message,
      spanId: spanId,
      traceId: traceId,
      data: data,
    );
    _events.add(logEvent);
    _onEvent(logEvent);
  }

  /// Create a child span (nested operation).
  LogSpanHandle startSpan(String childName, {Map<String, Object>? data}) {
    return LogSpanHandle(
      name: childName,
      scope: scope,
      parentSpanId: spanId,
      traceId: traceId,
      data: data,
      onComplete: _onComplete,
      onEvent: _onEvent,
      onStart: _onStart,
    );
  }

  /// Add metadata to the span.
  void addData(Map<String, Object> data) {
    if (_ended) return;
    _data = {...?_data, ...data};
  }

  /// End the span. Emits [LogSpan] to the pipeline.
  void end(
      {SpanStatus status = SpanStatus.ok,
      Object? error,
      StackTrace? stackTrace}) {
    if (_ended) return;
    _ended = true;

    final span = LogSpan(
      spanId: spanId,
      parentSpanId: parentSpanId,
      traceId: traceId,
      scope: scope,
      name: name,
      startTime: _startTime,
      endTime: DateTime.now(),
      status: status,
      error: error,
      stackTrace: stackTrace,
      data: _data,
      events: List.unmodifiable(_events),
    );

    _onComplete(span);
  }

  static final _random = Random();

  static String _generateSpanId() {
    final bytes = List<int>.generate(8, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
