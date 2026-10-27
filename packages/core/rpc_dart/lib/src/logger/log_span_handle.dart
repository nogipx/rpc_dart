// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'log_scope.dart';

typedef _SpanCompleteCallback = void Function(LogSpan span);
typedef _SpanEventCallback = void Function(LogEvent event);
typedef _SpanStartCallback = void Function(LogSpanStart start);
typedef _LevelCheck = bool Function(RpcLogLevel level);

/// The trace id and the span id of a W3C `traceparent`
/// (`00-<32 hex>-<16 hex>-<2 hex>`), or null when [traceparent] is not one:
/// another version, upper-case or wrong-length hex, or an all-zero id.
({String traceId, String spanId})? _parseTraceparent(String traceparent) {
  final m = _traceparent.firstMatch(traceparent);
  if (m == null) return null;
  final traceId = m.group(1)!;
  final spanId = m.group(2)!;
  if (_zero.hasMatch(traceId) || _zero.hasMatch(spanId)) return null;
  return (traceId: traceId, spanId: spanId);
}

final _traceparent = RegExp(r'^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$');
final _zero = RegExp(r'^0+$');
final _traceIdShape = RegExp(r'^[0-9a-f]{32}$');

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
  final _SpanCompleteCallback _onComplete;
  final _SpanEventCallback _onEvent;
  final _SpanStartCallback _onStart;
  final _LevelCheck _accepts;
  final DateTime Function() _clock;
  final List<LogEvent> _events = [];
  Map<String, Object>? _data;
  bool _ended = false;

  /// Made while spans are off: no ids and no records of its own; its
  /// events go out as plain events.
  final bool _detachedSpan;

  /// Creates a [LogSpanHandle] and immediately emits a [LogSpanStart].
  LogSpanHandle._({
    required this.name,
    required this.scope,
    required _SpanCompleteCallback onComplete,
    required _SpanEventCallback onEvent,
    required _SpanStartCallback onStart,
    required _LevelCheck accepts,
    this.parentSpanId,
    this.traceId,
    List<String> links = const [],
    Map<String, Object>? data,
    DateTime Function()? clock,
  }) : spanId = _randomHex(8),
       _detachedSpan = false,
       _clock = clock ?? DateTime.now,
       _startTime = (clock ?? DateTime.now)(),
       _onComplete = onComplete,
       _onEvent = onEvent,
       _onStart = onStart,
       _accepts = accepts,
       _data = data {
    onStart(
      LogSpanStart(
        spanId: spanId,
        scope: scope,
        name: name,
        parentSpanId: parentSpanId,
        traceId: traceId,
        links: links,
        timestamp: _startTime,
      ),
    );
  }

  /// A span made while [LogController.spansEnabled] is off: nothing is
  /// generated or emitted for it, and its events are told as events of no
  /// span, so turning spans off loses no log line.
  LogSpanHandle._detached({
    required this.scope,
    required _SpanEventCallback onEvent,
    required _LevelCheck accepts,
    DateTime Function()? clock,
  }) : name = '',
       spanId = '',
       parentSpanId = null,
       traceId = null,
       _clock = clock ?? DateTime.now,
       _startTime = DateTime.fromMicrosecondsSinceEpoch(0),
       _onComplete = _ignore,
       _onEvent = onEvent,
       _onStart = _ignore,
       _accepts = accepts,
       _detachedSpan = true;

  /// An already-ended span that emits nothing, for [LogScope.noop].
  LogSpanHandle._noop()
    : name = '',
      scope = '',
      spanId = '',
      parentSpanId = null,
      traceId = null,
      _clock = DateTime.now,
      _startTime = DateTime.fromMicrosecondsSinceEpoch(0),
      _onComplete = _ignore,
      _onEvent = _ignore,
      _onStart = _ignore,
      _accepts = _never,
      _detachedSpan = false {
    _ended = true;
  }

  static void _ignore(Object? _) {}
  static bool _never(RpcLogLevel _) => false;

  /// Whether this span has been ended.
  bool get isEnded => _ended;

  /// Whether an event at [level] would be kept: the span is open and its
  /// scope's filter takes the level. The guard for an event that builds
  /// its message or its `data`.
  bool isEnabled(RpcLogLevel level) => !_ended && _accepts(level);

  /// This span as a W3C `traceparent`, for a span in another process to
  /// join its trace ([LogScope.startSpan] `parent:`); null when its trace
  /// id is not a W3C one (a caller gave its own).
  String? get traceparent {
    final t = traceId;
    if (t == null || !_traceIdShape.hasMatch(t)) return null;
    return '00-$t-$spanId-01';
  }

  /// Add an event inside this span. One its scope's filter would drop is
  /// neither emitted nor kept in the span's [LogSpan.events].
  void event(
    String message, {
    RpcLogLevel level = RpcLogLevel.info,
    Map<String, Object>? data,
  }) {
    if (!isEnabled(level)) return;
    final logEvent = LogEvent(
      scope: scope,
      level: level,
      message: message,
      spanId: _detachedSpan ? null : spanId,
      traceId: traceId,
      data: data,
      timestamp: _clock(),
    );
    if (!_detachedSpan) _events.add(logEvent);
    _onEvent(logEvent);
  }

  /// Create a child span (nested operation).
  LogSpanHandle startSpan(String childName, {Map<String, Object>? data}) {
    if (_detachedSpan) return this;
    return LogSpanHandle._(
      name: childName,
      scope: scope,
      parentSpanId: spanId,
      traceId: traceId,
      data: data,
      onComplete: _onComplete,
      onEvent: _onEvent,
      onStart: _onStart,
      accepts: _accepts,
      clock: _clock,
    );
  }

  /// Add metadata to the span.
  void addData(Map<String, Object> data) {
    if (_ended) return;
    _data = {...?_data, ...data};
  }

  /// End the span. Emits [LogSpan] to the pipeline.
  void end({
    LogSpanStatus status = LogSpanStatus.ok,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_ended) return;
    _ended = true;
    if (_detachedSpan) return;

    final span = LogSpan(
      spanId: spanId,
      parentSpanId: parentSpanId,
      traceId: traceId,
      scope: scope,
      name: name,
      startTime: _startTime,
      endTime: _clock(),
      status: status,
      error: error,
      stackTrace: stackTrace,
      data: _data,
      events: List.unmodifiable(_events),
    );

    _onComplete(span);
  }

  static final _random = Random();

  /// [bytes] random bytes as lower-case hex: a span id (8), a trace id
  /// (16), never all zero, as W3C Trace Context forbids.
  static String _randomHex(int bytes) {
    while (true) {
      final b = List<int>.generate(bytes, (_) => _random.nextInt(256));
      if (b.any((x) => x != 0)) {
        return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      }
    }
  }
}
