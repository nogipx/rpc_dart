// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../log_filter.dart';
import '../log_level.dart';
import '../log_output.dart';
import '../log_record.dart';

/// In-memory circular buffer that keeps the last N log records.
///
/// Useful for: history queries, crash reports, in-app log viewer.
class RingBufferOutput extends LogOutput {
  /// Maximum number of records to keep in the buffer.
  final int maxEntries;
  final List<LogRecord?> _buffer;
  int _head = 0;
  int _count = 0;

  @override
  final String? scopeFilter;

  /// Creates a [RingBufferOutput] with optional capacity and scope filter.
  RingBufferOutput({this.maxEntries = 1000, this.scopeFilter})
    : _buffer = List<LogRecord?>.filled(maxEntries, null);

  @override
  void write(LogRecord record) {
    _buffer[_head] = record;
    _head = (_head + 1) % maxEntries;
    if (_count < maxEntries) _count++;
  }

  /// All buffered entries in chronological order.
  List<LogRecord> get entries {
    if (_count < maxEntries) {
      return List<LogRecord>.unmodifiable(
        _buffer.sublist(0, _count).cast<LogRecord>(),
      );
    }
    // Buffer is full -- entries wrap around
    return List<LogRecord>.unmodifiable([
      ..._buffer.sublist(_head).cast<LogRecord>(),
      ..._buffer.sublist(0, _head).cast<LogRecord>(),
    ]);
  }

  /// Query entries matching [filter], returning at most [limit] results.
  List<LogRecord> query(LogFilter filter, {int? limit}) {
    final all = entries;
    final results = <LogRecord>[];

    for (final record in all) {
      if (limit != null && results.length >= limit) break;

      final matches = switch (record) {
        LogSpanStart() => false, // span starts are transient, not queryable
        LogEvent event => filter.matches(
          level: event.level,
          scope: event.scope,
          tag: event.tag,
          traceId: event.traceId,
          requestId: event.requestId,
        ),
        LogSpan span => filter.matches(
          level: RpcLogLevel.info, // spans don't have a level; treat as info
          scope: span.scope,
          traceId: span.traceId,
        ),
      };

      if (matches) results.add(record);
    }

    return results;
  }

  /// Clear all buffered entries.
  void clear() {
    _buffer.fillRange(0, maxEntries, null);
    _head = 0;
    _count = 0;
  }

  /// Current number of entries in the buffer.
  int get length => _count;
}
