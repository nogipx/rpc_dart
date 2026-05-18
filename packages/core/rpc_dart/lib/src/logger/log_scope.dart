// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'log_controller.dart';
import 'log_level.dart';
import 'log_record.dart';
import 'log_span_handle.dart';

/// Lightweight logging handle bound to a scope name and controller.
///
/// All logging goes through [LogScope]. It does not know about outputs —
/// it only submits records to the [LogController] which handles filtering
/// and routing.
class LogScope {
  /// No-op logger. All methods are empty, zero cost.
  static final LogScope noop = _NoopLogScope();

  final LogController _controller;

  /// Scope name (e.g. 'rpc.transport.router').
  final String name;

  /// Optional tag for sub-categorization.
  final String? tag;

  /// Fields automatically merged into every record from this scope.
  final Map<String, Object>? _boundData;

  /// Trace ID bound to this scope (propagated to all records).
  final String? _traceId;

  /// Request ID bound to this scope.
  final String? _requestId;

  /// Parent span ID (for records emitted within a span context).
  final String? _parentSpanId;

  /// Clock function for timestamps. Inherited from [LogController].
  final DateTime Function() _clock;

  /// Creates a [LogScope] bound to [_controller] with the given [name].
  LogScope(
    this._controller,
    this.name, {
    this.tag,
    Map<String, Object>? boundData,
    String? traceId,
    String? requestId,
    String? parentSpanId,
    DateTime Function()? clock,
  })  : _boundData = boundData,
        _traceId = traceId,
        _requestId = requestId,
        _parentSpanId = parentSpanId,
        _clock = clock ?? DateTime.now;

  // --- Level guards for hot-path optimization ---

  /// Whether internal-level records pass the current filter.
  bool get isInternal => _controller.accepts(RpcLogLevel.internal, name);

  /// Whether trace-level records pass the current filter.
  bool get isTrace => _controller.accepts(RpcLogLevel.trace, name);

  /// Whether debug-level records pass the current filter.
  bool get isDebug => _controller.accepts(RpcLogLevel.debug, name);

  // --- Hierarchy ---

  /// Create a child scope with a dot-separated name.
  LogScope child(String childName, {String? tag}) {
    return LogScope(
      _controller,
      '$name.$childName',
      tag: tag ?? this.tag,
      boundData: _boundData,
      traceId: _traceId,
      requestId: _requestId,
      parentSpanId: _parentSpanId,
      clock: _clock,
    );
  }

  /// Create a new scope with a different tag.
  LogScope withTag(String tag) {
    return LogScope(
      _controller,
      name,
      tag: tag,
      boundData: _boundData,
      traceId: _traceId,
      requestId: _requestId,
      parentSpanId: _parentSpanId,
      clock: _clock,
    );
  }

  /// Create a new scope with additional bound data fields.
  /// These fields are automatically merged into every record.
  LogScope withData(Map<String, Object> data) {
    return LogScope(
      _controller,
      name,
      tag: tag,
      boundData: {...?_boundData, ...data},
      traceId: _traceId,
      requestId: _requestId,
      parentSpanId: _parentSpanId,
      clock: _clock,
    );
  }

  /// Create a new scope with RPC context (traceId, requestId).
  LogScope withContext({String? traceId, String? requestId}) {
    return LogScope(
      _controller,
      name,
      tag: tag,
      boundData: _boundData,
      traceId: traceId ?? _traceId,
      requestId: requestId ?? _requestId,
      parentSpanId: _parentSpanId,
      clock: _clock,
    );
  }

  // --- Event methods ---

  /// Log at [RpcLogLevel.internal] level.
  void internal(String message, {Map<String, Object>? data}) =>
      _log(RpcLogLevel.internal, message, data: data);

  /// Log at [RpcLogLevel.trace] level.
  void trace(String message, {Map<String, Object>? data}) =>
      _log(RpcLogLevel.trace, message, data: data);

  /// Log at [RpcLogLevel.debug] level.
  void debug(String message, {Map<String, Object>? data}) =>
      _log(RpcLogLevel.debug, message, data: data);

  /// Log at [RpcLogLevel.info] level.
  void info(String message, {Map<String, Object>? data}) =>
      _log(RpcLogLevel.info, message, data: data);

  /// Log at [RpcLogLevel.warning] level with optional error and stack trace.
  void warning(String message,
          {Object? error, StackTrace? stackTrace, Map<String, Object>? data}) =>
      _log(RpcLogLevel.warning, message,
          error: error, stackTrace: stackTrace, data: data);

  /// Log at [RpcLogLevel.error] level with optional error and stack trace.
  void error(String message,
          {Object? error, StackTrace? stackTrace, Map<String, Object>? data}) =>
      _log(RpcLogLevel.error, message,
          error: error, stackTrace: stackTrace, data: data);

  /// Log at [RpcLogLevel.fatal] level with optional error and stack trace.
  void fatal(String message,
          {Object? error, StackTrace? stackTrace, Map<String, Object>? data}) =>
      _log(RpcLogLevel.fatal, message,
          error: error, stackTrace: stackTrace, data: data);

  // --- Span methods ---

  /// Start a span. Must be ended explicitly via [LogSpanHandle.end].
  LogSpanHandle startSpan(String spanName,
      {Map<String, Object>? data, String? traceId}) {
    return LogSpanHandle(
      name: spanName,
      scope: name,
      parentSpanId: _parentSpanId,
      traceId: traceId ?? _traceId,
      data: data != null ? {...?_boundData, ...data} : _boundData,
      onComplete: (span) => _controller.add(span),
      onEvent: (event) => _controller.add(event),
      onStart: (start) => _controller.add(start),
      clock: _clock,
    );
  }

  /// Run [body] inside a span. Auto-ends with ok on return, error on throw.
  Future<T> withSpan<T>(
    String spanName,
    Future<T> Function(LogSpanHandle span) body, {
    Map<String, Object>? data,
  }) async {
    final span = startSpan(spanName, data: data);
    try {
      final result = await body(span);
      span.end(status: SpanStatus.ok);
      return result;
    } catch (e, st) {
      span.end(status: SpanStatus.error, error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Synchronous version of [withSpan].
  T withSpanSync<T>(
    String spanName,
    T Function(LogSpanHandle span) body, {
    Map<String, Object>? data,
  }) {
    final span = startSpan(spanName, data: data);
    try {
      final result = body(span);
      span.end(status: SpanStatus.ok);
      return result;
    } catch (e, st) {
      span.end(status: SpanStatus.error, error: e, stackTrace: st);
      rethrow;
    }
  }

  // --- Internal ---

  void _log(
    RpcLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object>? data,
  }) {
    if (!_controller.accepts(level, name, tag)) return;

    final mergedData =
        _boundData != null || data != null ? {...?_boundData, ...?data} : null;

    _controller.add(LogEvent(
      scope: name,
      level: level,
      message: message,
      tag: tag,
      error: error,
      stackTrace: stackTrace,
      traceId: _traceId,
      requestId: _requestId,
      spanId: _parentSpanId,
      data: mergedData,
      timestamp: _clock(),
    ));
  }
}

/// No-op implementation. All methods are empty.
class _NoopLogScope implements LogScope {
  _NoopLogScope();

  @override
  LogController get _controller => throw UnsupportedError('noop');
  @override
  String get name => '';
  @override
  String? get tag => null;
  @override
  Map<String, Object>? get _boundData => null;
  @override
  String? get _traceId => null;
  @override
  String? get _requestId => null;
  @override
  String? get _parentSpanId => null;
  @override
  DateTime Function() get _clock => DateTime.now;

  @override
  bool get isInternal => false;
  @override
  bool get isTrace => false;
  @override
  bool get isDebug => false;

  @override
  LogScope child(String childName, {String? tag}) => this;
  @override
  LogScope withTag(String tag) => this;
  @override
  LogScope withData(Map<String, Object> data) => this;
  @override
  LogScope withContext({String? traceId, String? requestId}) => this;

  @override
  void internal(String message, {Map<String, Object>? data}) {}
  @override
  void trace(String message, {Map<String, Object>? data}) {}
  @override
  void debug(String message, {Map<String, Object>? data}) {}
  @override
  void info(String message, {Map<String, Object>? data}) {}
  @override
  void warning(String message,
      {Object? error, StackTrace? stackTrace, Map<String, Object>? data}) {}
  @override
  void error(String message,
      {Object? error, StackTrace? stackTrace, Map<String, Object>? data}) {}
  @override
  void fatal(String message,
      {Object? error, StackTrace? stackTrace, Map<String, Object>? data}) {}

  @override
  LogSpanHandle startSpan(String spanName,
          {Map<String, Object>? data, String? traceId}) =>
      _NoopSpanHandle();
  @override
  Future<T> withSpan<T>(
          String spanName, Future<T> Function(LogSpanHandle span) body,
          {Map<String, Object>? data}) =>
      body(_NoopSpanHandle());
  @override
  T withSpanSync<T>(String spanName, T Function(LogSpanHandle span) body,
          {Map<String, Object>? data}) =>
      body(_NoopSpanHandle());

  @override
  void _log(RpcLogLevel level, String message,
      {Object? error, StackTrace? stackTrace, Map<String, Object>? data}) {}
}

class _NoopSpanHandle implements LogSpanHandle {
  @override
  String get spanId => '';
  @override
  String get name => '';
  @override
  String get scope => '';
  @override
  String? get parentSpanId => null;
  @override
  String? get traceId => null;
  @override
  bool get isEnded => true;
  @override
  void event(String message,
      {RpcLogLevel level = RpcLogLevel.info, Map<String, Object>? data}) {}
  @override
  LogSpanHandle startSpan(String childName, {Map<String, Object>? data}) =>
      this;
  @override
  void addData(Map<String, Object> data) {}
  @override
  void end(
      {SpanStatus status = SpanStatus.ok,
      Object? error,
      StackTrace? stackTrace}) {}
}
