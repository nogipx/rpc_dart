// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'log_level.dart';

/// Base type for all log records flowing through the pipeline.
sealed class LogRecord {
  /// Scope name (e.g. 'rpc.transport.router').
  String get scope;

  /// When this record was created.
  DateTime get timestamp;

  /// Structured metadata.
  Map<String, Object>? get data;
}

/// Marks the beginning of a span.
class LogSpanStart implements LogRecord {
  @override
  final String scope;

  @override
  final DateTime timestamp;

  @override
  Map<String, Object>? get data => null;

  /// Span identifier (matches the [LogSpan.spanId] emitted on end).
  final String spanId;

  /// Parent span ID — set when this span was created via
  /// [LogSpanHandle.startSpan]. Lets downstream bridges (e.g. OpenTelemetry)
  /// link nested spans without waiting for the parent's [LogSpan] end record.
  final String? parentSpanId;

  /// Trace ID for distributed tracing correlation.
  final String? traceId;

  /// Operation name.
  final String name;

  /// Creates a [LogSpanStart] record.
  LogSpanStart({
    required this.spanId,
    required this.scope,
    required this.name,
    this.parentSpanId,
    this.traceId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// A point-in-time log event.
class LogEvent implements LogRecord {
  @override
  final String scope;

  @override
  final DateTime timestamp;

  @override
  final Map<String, Object>? data;

  /// Severity level.
  final RpcLogLevel level;

  /// Human-readable message.
  final String message;

  /// Optional sub-category for filtering.
  final String? tag;

  /// Error object (for error/fatal levels).
  final Object? error;

  /// Stack trace (for error/fatal levels).
  final StackTrace? stackTrace;

  /// RPC trace correlation ID.
  final String? traceId;

  /// RPC request correlation ID.
  final String? requestId;

  /// Span ID if this event occurred inside a span.
  final String? spanId;

  /// Creates a [LogEvent] record.
  LogEvent({
    required this.scope,
    required this.level,
    required this.message,
    this.tag,
    this.error,
    this.stackTrace,
    this.traceId,
    this.requestId,
    this.spanId,
    this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Serializes this event to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'type': 'event',
    'scope': scope,
    'level': level.name,
    'message': message,
    if (tag != null) 'tag': tag,
    if (error != null) 'error': error.toString(),
    if (stackTrace != null) 'stackTrace': stackTrace.toString(),
    if (traceId != null) 'traceId': traceId,
    if (requestId != null) 'requestId': requestId,
    if (spanId != null) 'spanId': spanId,
    if (data != null) 'data': data,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };

  /// Deserializes a [LogEvent] from a JSON-compatible map.
  factory LogEvent.fromJson(Map<String, dynamic> json) => LogEvent(
    scope: json['scope'] as String? ?? '',
    level: RpcLogLevel.values.firstWhere(
      (e) => e.name == json['level'],
      orElse: () => RpcLogLevel.info,
    ),
    message: json['message'] as String? ?? '',
    tag: json['tag'] as String?,
    error: json['error'],
    traceId: json['traceId'] as String?,
    requestId: json['requestId'] as String?,
    spanId: json['spanId'] as String?,
    data: (json['data'] as Map<String, dynamic>?)?.cast<String, Object>(),
    timestamp: json['timestamp'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int)
        : null,
  );
}

/// Status of a completed span.
enum SpanStatus {
  /// Span completed successfully.
  ok,

  /// Span completed with an error.
  error,
}

/// A completed operation span with duration.
class LogSpan implements LogRecord {
  @override
  final String scope;

  @override
  final DateTime timestamp;

  @override
  final Map<String, Object>? data;

  /// Unique span identifier.
  final String spanId;

  /// Parent span ID (for nested spans).
  final String? parentSpanId;

  /// Trace ID for distributed tracing.
  final String? traceId;

  /// Operation name.
  final String name;

  /// When the span started.
  final DateTime startTime;

  /// When the span ended.
  final DateTime endTime;

  /// How long the operation took.
  Duration get duration => endTime.difference(startTime);

  /// Outcome of the operation.
  final SpanStatus status;

  /// Error (if status == error).
  final Object? error;

  /// Stack trace (if status == error).
  final StackTrace? stackTrace;

  /// Events that occurred inside this span.
  final List<LogEvent> events;

  /// Creates a [LogSpan] record.
  LogSpan({
    required this.spanId,
    required this.scope,
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.status,
    this.parentSpanId,
    this.traceId,
    this.error,
    this.stackTrace,
    this.data,
    this.events = const [],
  }) : timestamp = endTime;

  /// Serializes this span to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
    'type': 'span',
    'spanId': spanId,
    if (parentSpanId != null) 'parentSpanId': parentSpanId,
    if (traceId != null) 'traceId': traceId,
    'scope': scope,
    'name': name,
    'startTime': startTime.millisecondsSinceEpoch,
    'endTime': endTime.millisecondsSinceEpoch,
    'durationMs': duration.inMilliseconds,
    'status': status.name,
    if (error != null) 'error': error.toString(),
    if (stackTrace != null) 'stackTrace': stackTrace.toString(),
    if (data != null) 'data': data,
    if (events.isNotEmpty) 'events': events.map((e) => e.toJson()).toList(),
  };

  /// Deserializes a [LogSpan] from a JSON-compatible map.
  factory LogSpan.fromJson(Map<String, dynamic> json) => LogSpan(
    spanId: json['spanId'] as String? ?? '',
    parentSpanId: json['parentSpanId'] as String?,
    traceId: json['traceId'] as String?,
    scope: json['scope'] as String? ?? '',
    name: json['name'] as String? ?? '',
    startTime: DateTime.fromMillisecondsSinceEpoch(
      json['startTime'] as int? ?? 0,
    ),
    endTime: DateTime.fromMillisecondsSinceEpoch(json['endTime'] as int? ?? 0),
    status: json['status'] == 'error' ? SpanStatus.error : SpanStatus.ok,
    error: json['error'],
    data: (json['data'] as Map<String, dynamic>?)?.cast<String, Object>(),
    events:
        (json['events'] as List<dynamic>?)
            ?.map((e) => LogEvent.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}
