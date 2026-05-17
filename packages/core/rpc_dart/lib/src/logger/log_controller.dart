// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'log_enricher.dart';
import 'log_level.dart';
import 'log_output.dart';
import 'log_record.dart';
import 'log_scope.dart';
import 'redaction.dart';
import 'sampling.dart';

/// Central log dispatcher.
///
/// Owns the processing pipeline: filter -> sample -> enrich -> redact -> route to outputs.
/// Created by the user, injected into endpoints.
class LogController {
  /// Global minimum log level. Records below this are discarded.
  RpcLogLevel minLevel;

  final Map<String, RpcLogLevel> _scopeLevels = {};
  final Map<String, RpcLogLevel> _tagLevels = {};
  final List<LogOutput> _outputs;
  final List<LogEnricher> _enrichers;
  final LogRedactor? _redactor;
  final SamplingState? _sampling;

  final StreamController<LogRecord> _streamController =
      StreamController<LogRecord>.broadcast();
  bool _disposed = false;

  LogController({
    this.minLevel = RpcLogLevel.debug,
    this.spansEnabled = true,
    List<LogOutput> outputs = const [],
    List<LogEnricher> enrichers = const [],
    SamplingConfig? sampling,
    List<String> redactFields = const [],
  })  : _outputs = List.of(outputs),
        _enrichers = List.of(enrichers),
        _redactor = redactFields.isNotEmpty
            ? LogRedactor(fields: redactFields)
            : null,
        _sampling = sampling != null ? SamplingState(sampling) : null;

  // --- Level filtering ---

  /// Set minimum level for a specific scope prefix.
  void setScopeLevel(String scope, RpcLogLevel level) {
    _scopeLevels[scope] = level;
  }

  /// Remove scope-specific level override.
  void clearScopeLevel(String scope) {
    _scopeLevels.remove(scope);
  }

  /// Set minimum level for a specific tag.
  void setTagLevel(String tag, RpcLogLevel level) {
    _tagLevels[tag] = level;
  }

  /// Remove tag-specific level override.
  void clearTagLevel(String tag) {
    _tagLevels.remove(tag);
  }

  /// Quick check whether a record at [level] from [scope] would pass filtering.
  /// Used by [LogScope] guards (isTrace, isInternal) to avoid unnecessary work.
  bool accepts(RpcLogLevel level, String scope) {
    final threshold = _resolveLevel(scope, null);
    return level >= threshold;
  }

  // --- Output management ---

  void addOutput(LogOutput output) {
    _outputs.add(output);
  }

  void removeOutput(LogOutput output) {
    _outputs.remove(output);
  }

  // --- Entry point ---

  /// Whether spans are emitted. Defaults to true.
  /// Spans bypass level filtering (they are telemetry, not log messages),
  /// but can be disabled entirely via this flag.
  bool spansEnabled;

  /// Submit a log record to the pipeline. Synchronous, non-blocking.
  void add(LogRecord record) {
    if (_disposed) return;

    // Spans bypass level filter and sampling — they are structural telemetry,
    // not log messages. A span records that an operation happened and how long
    // it took, regardless of the current log verbosity level.
    // Events inside spans are still filtered normally.
    if (record is LogSpan || record is LogSpanStart) {
      if (!spansEnabled) return;
    }

    // Step 1: Level/scope filter (events only)
    if (record is LogEvent) {
      if (!_acceptsEvent(record)) return;

      // Step 2: Sampling (events only)
      if (_sampling != null && !_sampling!.shouldKeep(record.level)) return;
    }

    // Step 3: Enrich
    var enrichedRecord = record;
    if (_enrichers.isNotEmpty && record.data != null || _enrichers.isNotEmpty) {
      enrichedRecord = _enrich(record);
    }

    // Step 4: Redact
    if (_redactor != null && _redactor!.isActive && enrichedRecord.data != null) {
      enrichedRecord = _redact(enrichedRecord);
    }

    // Step 5: Route to outputs
    for (final output in _outputs) {
      final filter = output.scopeFilter;
      if (filter != null && !enrichedRecord.scope.startsWith(filter)) continue;
      output.write(enrichedRecord);
    }

    // Step 6: Stream
    if (_streamController.hasListener) {
      _streamController.add(enrichedRecord);
    }
  }

  /// Broadcast stream of records that passed all filters.
  Stream<LogRecord> get stream => _streamController.stream;

  // --- Scope creation ---

  /// Create a scoped logger bound to this controller.
  LogScope scope(String name, {String? tag}) {
    return LogScope(this, name, tag: tag);
  }

  // --- Current configuration (for remote control) ---

  LogConfig get config => LogConfig(
        minLevel: minLevel,
        scopeLevels: Map.unmodifiable(_scopeLevels),
        tagLevels: Map.unmodifiable(_tagLevels),
      );

  // --- Lifecycle ---

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final output in _outputs) {
      output.dispose();
    }
    _outputs.clear();
    _streamController.close();
  }

  // --- Private ---

  bool _acceptsEvent(LogEvent event) {
    final threshold = _resolveLevel(event.scope, event.tag);
    return event.level >= threshold;
  }

  RpcLogLevel _resolveLevel(String scope, String? tag) {
    // Check tag override first
    if (tag != null) {
      final tagLevel = _tagLevels[tag];
      if (tagLevel != null) return tagLevel;
    }

    // Check scope overrides (longest prefix match)
    RpcLogLevel? best;
    int bestLength = -1;
    for (final entry in _scopeLevels.entries) {
      if (scope.startsWith(entry.key) && entry.key.length > bestLength) {
        best = entry.value;
        bestLength = entry.key.length;
      }
    }
    if (best != null) return best;

    return minLevel;
  }

  LogRecord _enrich(LogRecord record) {
    var extra = <String, Object>{};
    for (final enricher in _enrichers) {
      extra.addAll(enricher.enrich(record));
    }
    if (extra.isEmpty) return record;

    final merged = {...?record.data, ...extra};
    if (record is LogEvent) {
      return LogEvent(
        scope: record.scope,
        level: record.level,
        message: record.message,
        tag: record.tag,
        error: record.error,
        stackTrace: record.stackTrace,
        traceId: record.traceId,
        requestId: record.requestId,
        spanId: record.spanId,
        data: merged,
        timestamp: record.timestamp,
      );
    } else if (record is LogSpan) {
      return LogSpan(
        spanId: record.spanId,
        parentSpanId: record.parentSpanId,
        traceId: record.traceId,
        scope: record.scope,
        name: record.name,
        startTime: record.startTime,
        endTime: record.endTime,
        status: record.status,
        error: record.error,
        stackTrace: record.stackTrace,
        data: merged,
        events: record.events,
      );
    }
    return record;
  }

  LogRecord _redact(LogRecord record) {
    final data = record.data;
    if (data == null) return record;
    final redacted = _redactor!.redact(data);

    if (record is LogEvent) {
      return LogEvent(
        scope: record.scope,
        level: record.level,
        message: record.message,
        tag: record.tag,
        error: record.error,
        stackTrace: record.stackTrace,
        traceId: record.traceId,
        requestId: record.requestId,
        spanId: record.spanId,
        data: redacted,
        timestamp: record.timestamp,
      );
    } else if (record is LogSpan) {
      return LogSpan(
        spanId: record.spanId,
        parentSpanId: record.parentSpanId,
        traceId: record.traceId,
        scope: record.scope,
        name: record.name,
        startTime: record.startTime,
        endTime: record.endTime,
        status: record.status,
        error: record.error,
        stackTrace: record.stackTrace,
        data: redacted,
        events: record.events,
      );
    }
    return record;
  }
}

/// Snapshot of controller configuration (for remote control / diagnostics).
class LogConfig {
  final RpcLogLevel minLevel;
  final Map<String, RpcLogLevel> scopeLevels;
  final Map<String, RpcLogLevel> tagLevels;

  const LogConfig({
    required this.minLevel,
    this.scopeLevels = const {},
    this.tagLevels = const {},
  });

  Map<String, dynamic> toJson() => {
        'minLevel': minLevel.name,
        if (scopeLevels.isNotEmpty)
          'scopeLevels': scopeLevels.map((k, v) => MapEntry(k, v.name)),
        if (tagLevels.isNotEmpty)
          'tagLevels': tagLevels.map((k, v) => MapEntry(k, v.name)),
      };

  factory LogConfig.fromJson(Map<String, dynamic> json) => LogConfig(
        minLevel: RpcLogLevel.values.firstWhere(
          (e) => e.name == json['minLevel'],
          orElse: () => RpcLogLevel.debug,
        ),
        scopeLevels: (json['scopeLevels'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(
                k,
                RpcLogLevel.values.firstWhere(
                  (e) => e.name == v,
                  orElse: () => RpcLogLevel.debug,
                ),
              ),
            ) ??
            const {},
        tagLevels: (json['tagLevels'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(
                k,
                RpcLogLevel.values.firstWhere(
                  (e) => e.name == v,
                  orElse: () => RpcLogLevel.debug,
                ),
              ),
            ) ??
            const {},
      );
}
