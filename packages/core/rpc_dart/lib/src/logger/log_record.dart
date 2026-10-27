// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'log_level.dart';

/// Base type for all log records flowing through the pipeline.
///
/// Open: a minor release may add a record type, so a `switch` keeps a
/// default.
sealed class LogRecord {
  /// Scope name (e.g. 'rpc.transport.router').
  String get scope;

  /// When this record was created.
  DateTime get timestamp;

  /// Structured metadata.
  Map<String, Object>? get data;

  /// Trace ID for distributed tracing correlation.
  String? get traceId;
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

  @override
  final String? traceId;

  /// Operation name.
  final String name;

  /// Spans this one follows from without being their child, each a W3C
  /// `traceparent` (`LogScope.startSpan(links:)`): what a message said led
  /// to, when the span that said it may long be over.
  final List<String> links;

  /// Creates a [LogSpanStart] record.
  LogSpanStart({
    required this.spanId,
    required this.scope,
    required this.name,
    this.parentSpanId,
    this.traceId,
    this.links = const [],
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

  @override
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

  /// A copy with the given fields replaced. A null argument keeps the field.
  LogEvent copyWith({
    String? scope,
    RpcLogLevel? level,
    String? message,
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    String? traceId,
    String? requestId,
    String? spanId,
    Map<String, Object>? data,
    DateTime? timestamp,
  }) => LogEvent(
    scope: scope ?? this.scope,
    level: level ?? this.level,
    message: message ?? this.message,
    tag: tag ?? this.tag,
    error: error ?? this.error,
    stackTrace: stackTrace ?? this.stackTrace,
    traceId: traceId ?? this.traceId,
    requestId: requestId ?? this.requestId,
    spanId: spanId ?? this.spanId,
    data: data ?? this.data,
    timestamp: timestamp ?? this.timestamp,
  );

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
    level: RpcLogLevel.fromName(json['level'] as String?) ?? RpcLogLevel.info,
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
///
/// Open: a minor release may add a value, so a `switch` keeps a default.
enum LogSpanStatus {
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

  @override
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
  final LogSpanStatus status;

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

  /// A copy with the given fields replaced. A null argument keeps the field.
  LogSpan copyWith({
    String? spanId,
    String? scope,
    String? name,
    DateTime? startTime,
    DateTime? endTime,
    LogSpanStatus? status,
    String? parentSpanId,
    String? traceId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object>? data,
    List<LogEvent>? events,
  }) => LogSpan(
    spanId: spanId ?? this.spanId,
    scope: scope ?? this.scope,
    name: name ?? this.name,
    startTime: startTime ?? this.startTime,
    endTime: endTime ?? this.endTime,
    status: status ?? this.status,
    parentSpanId: parentSpanId ?? this.parentSpanId,
    traceId: traceId ?? this.traceId,
    error: error ?? this.error,
    stackTrace: stackTrace ?? this.stackTrace,
    data: data ?? this.data,
    events: events ?? this.events,
  );

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
    status: json['status'] == 'error' ? LogSpanStatus.error : LogSpanStatus.ok,
    error: json['error'],
    data: (json['data'] as Map<String, dynamic>?)?.cast<String, Object>(),
    events:
        (json['events'] as List<dynamic>?)
            ?.map((e) => LogEvent.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}
