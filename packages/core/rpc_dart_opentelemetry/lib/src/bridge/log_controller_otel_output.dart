// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:fixnum/fixnum.dart';
import 'package:opentelemetry/api.dart';
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
///
/// Open spans are bounded to prevent unbounded map growth when an end record
/// never arrives (e.g. a crashed scope). Two guards apply:
/// - [maxOpenSpans]: when the open map exceeds this size, the oldest open
///   spans are ended (LRU eviction) until it fits. This is the primary bound.
/// - [spanTtl]: a periodic sweep ends any open span older than this TTL. This
///   is a leak-guard for genuinely-abandoned spans, NOT a cap on normal span
///   duration, so it defaults to a generous 5 minutes — a span legitimately
///   doing work for several seconds must not be force-ended mid-flight.
/// An evicted span is ended (and thus exported) so nothing leaks.
///
/// **One trace across processes.** A log span names its place in a trace as
/// a W3C `traceparent` (`LogSpanHandle.traceparent`); a span in another
/// process opened with it (`LogScope.startSpan(parent:)`) arrives here with
/// a parent this output never opened, and is made a child of that remote
/// span context. For the remote child to find its parent, the OTel span of
/// the parent must carry the log span's own ids: give the tracer's provider
/// a [LogSpanIds] and pass the same one here as [ids]:
///
/// ```dart
/// final ids = LogSpanIds();
/// final provider = TracerProviderBase(idGenerator: ids, processors: [...]);
/// LogControllerOtelOutput(tracer: provider.getTracer('svc'), ids: ids);
/// ```
///
/// Without it, spans still nest within a process, but each OTel span has
/// ids of its own, so a remote child joins a trace no exporter has seen.
/// A log span nested under [rootContextProvider]'s span joins that span's
/// trace in OTel, not the log trace its traceparent names.
class LogControllerOtelOutput extends LogOutput {
  final Tracer _tracer;
  final Context Function()? _rootContextProvider;
  final LogSpanIds? _ids;

  /// Open spans keyed by spanId. A [LinkedHashMap] preserves insertion order
  /// so the first entry is always the oldest (used for size-based eviction).
  final LinkedHashMap<String, _OpenSpan> _open =
      LinkedHashMap<String, _OpenSpan>();

  final int _maxOpenSpans;
  final Duration _spanTtl;
  Timer? _sweepTimer;

  LogControllerOtelOutput({
    required Tracer tracer,
    Context Function()? rootContextProvider,
    int maxOpenSpans = 1024,
    Duration spanTtl = const Duration(minutes: 5),
    Duration sweepInterval = const Duration(seconds: 30),
    LogSpanIds? ids,
  }) : assert(maxOpenSpans > 0),
       _tracer = tracer,
       _rootContextProvider = rootContextProvider,
       _ids = ids,
       _maxOpenSpans = maxOpenSpans,
       _spanTtl = spanTtl {
    _sweepTimer = Timer.periodic(sweepInterval, (_) => _sweepExpired());
  }

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
    _sweepTimer?.cancel();
    _sweepTimer = null;
    for (final entry in _open.values) {
      _endQuietly(entry.span);
    }
    _open.clear();
  }

  // ---------------------------------------------------------------------------

  /// Ends [span], swallowing an export failure so the spans after it still
  /// end. Not logged: this is a LogOutput, and logging the failure would
  /// re-enter the controller that feeds it.
  static void _endQuietly(Span? span) {
    try {
      span?.end();
    } catch (_) {}
  }

  /// Ends any open span older than [_spanTtl] so the map cannot grow without
  /// bound when end records never arrive.
  void _sweepExpired() {
    if (_open.isEmpty) return;
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in _open.entries) {
      if (now.difference(entry.value.openedAt) >= _spanTtl) {
        expired.add(entry.key);
      }
    }
    for (final key in expired) {
      final entry = _open.remove(key);
      _endQuietly(entry?.span);
    }
  }

  /// Ends the oldest open spans (LRU by insertion order) until the map is
  /// within [_maxOpenSpans].
  void _evictOverflow() {
    while (_open.length > _maxOpenSpans) {
      final oldestKey = _open.keys.first;
      final entry = _open.remove(oldestKey);
      _endQuietly(entry?.span);
    }
  }

  void _onStart(LogSpanStart record) {
    final root = _rootContextProvider?.call() ?? Context.current;
    final parentId = record.parentSpanId;
    final parent = parentId != null ? _open[parentId]?.span : null;
    final traceId = record.traceId;
    // The span of the work running now, which the logger named as this
    // span's parent (`LogController.ambientParent`): the root holds it.
    final ambient =
        parent == null &&
        parentId != null &&
        '${spanContextFromContext(root).spanId}' == parentId;
    // A parent this output never opened, named by W3C ids: a span of
    // another process this one continues.
    final remote = parent == null && !ambient && traceId != null
        ? _remote(traceId, parentId)
        : null;
    final parentContext = parent != null
        ? contextWithSpan(root, parent)
        : remote != null
        ? contextWithSpanContext(root, remote)
        : root;
    final links = [
      for (final l in record.links)
        if (_fromTraceparent(l) case final c?) SpanLink(c),
    ];

    _ids?._next(record.spanId, traceId);
    final Span span;
    try {
      span = _tracer.startSpan(
        record.name,
        context: parentContext,
        kind: SpanKind.internal,
        startTime: _toInt64(record.timestamp),
        links: links,
        attributes: [
          Attribute.fromString('log.scope', record.scope),
          if (traceId != null) Attribute.fromString('log.trace_id', traceId),
        ],
      );
    } finally {
      _ids?._clear();
    }

    _open[record.spanId] = _OpenSpan(span, DateTime.now());
    _evictOverflow();
  }

  /// The remote span context of [traceId] and [spanId], when both are W3C.
  static SpanContext? _remote(String traceId, String? spanId) =>
      spanId != null &&
          LogSpanIds._isTraceId(traceId) &&
          LogSpanIds._isSpanId(spanId)
      ? SpanContext.remote(
          TraceId.fromString(traceId),
          SpanId.fromString(spanId),
          TraceFlags.sampled,
          TraceState.empty(),
        )
      : null;

  static SpanContext? _fromTraceparent(String traceparent) {
    final parts = traceparent.split('-');
    if (parts.length != 4 || parts[0] != '00') return null;
    return _remote(parts[1], parts[2]);
  }

  void _onEvent(LogEvent record) {
    final spanId = record.spanId;
    if (spanId != null) {
      final entry = _open[spanId];
      if (entry != null) {
        entry.span.addEvent(
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
    final entry = _open.remove(record.spanId);
    if (entry == null) return; // start was never seen (or already closed).
    final span = entry.span;

    if (record.data != null) {
      for (final entry in record.data!.entries) {
        span.setAttribute(_attribute(entry.key, entry.value));
      }
    }
    if (record.status == LogSpanStatus.error) {
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
        Attribute.fromString(
          'exception.stacktrace',
          record.stackTrace.toString(),
        ),
      if (record.traceId != null)
        Attribute.fromString('log.trace_id', record.traceId!),
      if (record.requestId != null)
        Attribute.fromString('log.request_id', record.requestId!),
      if (record.data != null)
        for (final entry in record.data!.entries)
          _attribute(entry.key, entry.value),
    ];
  }

  Attribute _attribute(String key, Object value) {
    if (value is int) return Attribute.fromInt(key, value);
    if (value is double) return Attribute.fromDouble(key, value);
    if (value is bool) return Attribute.fromBoolean(key, value);
    return Attribute.fromString(key, value.toString());
  }

  Int64 _toInt64(DateTime t) {
    // OTel SDK expects nanoseconds since epoch. We use fixnum [Int64] (not a
    // plain int) so the *1000 stays exact past 2^53 on dart2js, where the web
    // int is a JS double.
    //
    // dart2js caveat: [DateTime.microsecondsSinceEpoch] only has millisecond
    // resolution on the web (the sub-millisecond digits are always 000), so
    // span timestamps are rounded to the nearest millisecond there. This does
    // not break anything — the value is still a valid nanosecond epoch and
    // ordering is preserved — it only reduces timestamp precision.
    return Int64(t.microsecondsSinceEpoch) * 1000;
  }
}

/// An open OTel span plus the wall-clock instant it was opened, used for
/// TTL-based eviction of un-ended spans.
class _OpenSpan {
  final Span span;
  final DateTime openedAt;
  _OpenSpan(this.span, this.openedAt);
}

/// The ids of the OTel spans [LogControllerOtelOutput] opens, for the
/// tracer's provider (`TracerProviderBase(idGenerator:)`): each such span
/// gets the log span's own span id, and a root span the log span's trace
/// id, so a log span's `traceparent` names its OTel span and a span another
/// process opens with it joins the same OTel trace. Every other span (an
/// interceptor's, one of the app's own) gets random ids, as without it.
///
/// Give the same instance to the provider and to the output.
final class LogSpanIds implements IdGenerator {
  LogSpanIds({Random? random}) : _random = random ?? Random();

  final Random _random;
  List<int>? _span;
  List<int>? _trace;

  /// The ids of the log span the output is about to open; a trace id only
  /// when it is a W3C one.
  void _next(String spanId, String? traceId) {
    _span = _isSpanId(spanId) ? _bytes(spanId) : null;
    _trace = traceId != null && _isTraceId(traceId) ? _bytes(traceId) : null;
  }

  /// The tracer asks for a trace id only for a root span: what it did not
  /// take must not reach the next span.
  void _clear() => _span = _trace = null;

  @override
  List<int> generateSpanId() {
    final s = _span;
    _span = null;
    return s ?? _randomBytes(8);
  }

  @override
  List<int> generateTraceId() {
    final t = _trace;
    _trace = null;
    return t ?? _randomBytes(16);
  }

  List<int> _randomBytes(int n) {
    while (true) {
      final b = List<int>.generate(n, (_) => _random.nextInt(256));
      if (b.any((x) => x != 0)) return b;
    }
  }

  static final _traceIdShape = RegExp(r'^[0-9a-f]{32}$');
  static final _spanIdShape = RegExp(r'^[0-9a-f]{16}$');
  static final _zero = RegExp(r'^0+$');

  static bool _isTraceId(String id) =>
      _traceIdShape.hasMatch(id) && !_zero.hasMatch(id);
  static bool _isSpanId(String id) =>
      _spanIdShape.hasMatch(id) && !_zero.hasMatch(id);

  static List<int> _bytes(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}
