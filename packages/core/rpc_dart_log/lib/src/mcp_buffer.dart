// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:collection';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';

import 'log_server.dart';
import 'protocol.dart';

/// Holds buffered log records and exposes MCP query methods.
///
/// Maintains incremental stats (O(1) for [sources]) updated on each [addRecord].
/// Extracted from [LogCollectorMcpServer] to enable unit testing without a live
/// WebSocket server.
class LogCollectorMcpBuffer {
  final int maxRecords;

  // ListQueue gives O(1) indexed access AND amortized O(1) removeFirst(),
  // so oldest-eviction is O(1) instead of List.removeAt(0)'s O(n) shift.
  final ListQueue<TaggedRecord> _records = ListQueue();
  int _cursor = 0;

  // Incremental stats
  final Map<String, _ScopeStats> _scopeStats = {};
  final Map<String, int> _traceErrorCounts = {};
  final List<String> _traceIdOrder = []; // capped at _maxTraceIds
  int _totalErrors = 0;
  int _totalWarnings = 0;

  // Deduplicated recent errors: key = device|scope|message
  final Map<String, ({int count, TaggedRecord last})> _uniqueErrors = {};
  final List<String> _uniqueErrorKeys = []; // insertion order, max 5

  static const _maxTraceIds = 500;

  LogCollectorMcpBuffer({this.maxRecords = 5000});

  int get cursor => _cursor;
  int get recordCount => _records.length;

  // ---------------------------------------------------------------------------
  // Mutation
  // ---------------------------------------------------------------------------

  void addRecord(TaggedRecord tagged) {
    _records.add(tagged);
    _cursor++;
    while (_records.length > maxRecords) {
      _records.removeFirst();
    }

    final r = tagged.record;
    _scopeStats.putIfAbsent(r.scope, _ScopeStats.new).add(r);

    String? tid;
    if (r is LogEvent) tid = r.traceId;
    if (r is LogSpan) tid = r.traceId;
    if (tid != null) {
      if (!_traceErrorCounts.containsKey(tid)) {
        if (_traceIdOrder.length >= _maxTraceIds) {
          _traceErrorCounts.remove(_traceIdOrder.removeAt(0));
        }
        _traceIdOrder.add(tid);
        _traceErrorCounts[tid] = 0;
      }
      if (r is LogEvent &&
          (r.level == RpcLogLevel.error || r.level == RpcLogLevel.fatal)) {
        _traceErrorCounts[tid] = _traceErrorCounts[tid]! + 1;
      }
    }

    if (r is LogEvent) {
      if (r.level == RpcLogLevel.error || r.level == RpcLogLevel.fatal) {
        _totalErrors++;
        _addUniqueError(tagged, r);
      } else if (r.level == RpcLogLevel.warning) {
        _totalWarnings++;
      }
    }
  }

  void _addUniqueError(TaggedRecord tagged, LogEvent r) {
    final key = '${tagged.deviceLabel}|${r.scope}|${r.message}';
    if (_uniqueErrors.containsKey(key)) {
      final existing = _uniqueErrors[key]!;
      _uniqueErrors[key] = (count: existing.count + 1, last: tagged);
    } else {
      if (_uniqueErrorKeys.length >= 5) {
        _uniqueErrors.remove(_uniqueErrorKeys.removeAt(0));
      }
      _uniqueErrorKeys.add(key);
      _uniqueErrors[key] = (count: 1, last: tagged);
    }
  }

  // ---------------------------------------------------------------------------
  // MCP tools
  // ---------------------------------------------------------------------------

  String sources(List<LogCollectorSession> sessions) {
    final buf = StringBuffer();

    if (sessions.isEmpty) {
      buf.writeln('Devices: none connected');
    } else {
      buf.writeln('Devices (${sessions.length}):');
      for (final s in sessions) {
        buf.writeln('  ${s.label} [${s.app}] since ${_fmtTime(s.connectedAt)}');
      }
    }

    if (_records.isEmpty) {
      buf.writeln('Buffer: empty');
      return buf.toString();
    }

    final first = _records.first.record.timestamp;
    final last = _records.last.record.timestamp;
    final overflow = _records.length >= maxRecords
        ? ' (buffer full -- oldest evicted)'
        : '';
    buf.writeln(
      'Buffer: ${_records.length} records | ${_fmtTime(first)} - ${_fmtTime(last)} | cursor: $_cursor$overflow',
    );

    final totalParts = <String>[];
    if (_totalErrors > 0) totalParts.add('$_totalErrors errors');
    if (_totalWarnings > 0) totalParts.add('$_totalWarnings warnings');
    if (totalParts.isNotEmpty) buf.writeln('Totals: ${totalParts.join(', ')}');

    const maxScopes = 15;
    final sortedScopes = _scopeStats.entries.toList()
      ..sort((a, b) => b.value.total.compareTo(a.value.total));
    buf.writeln('Scopes:');
    for (final entry in sortedScopes.take(maxScopes)) {
      buf.writeln('  ${entry.key}: ${entry.value}');
    }
    if (sortedScopes.length > maxScopes) {
      buf.writeln('  ... +${sortedScopes.length - maxScopes} more scopes');
    }

    if (_uniqueErrorKeys.isNotEmpty) {
      buf.writeln('Recent errors (${_uniqueErrorKeys.length} unique):');
      for (final key in _uniqueErrorKeys) {
        final e = _uniqueErrors[key]!;
        final prefix = e.count > 1 ? '[x${e.count}] ' : '';
        buf.writeln('  $prefix${_formatTaggedRecord(e.last)}');
      }
    }

    if (_traceIdOrder.isNotEmpty) {
      const maxTrace = 10;
      final shown = _traceIdOrder.take(maxTrace).toList();
      final parts = shown
          .map((tid) {
            final prefix = tid.length > 8 ? tid.substring(0, 8) : tid;
            final errs = _traceErrorCounts[tid]!;
            return errs > 0 ? '$prefix ($errs err)' : prefix;
          })
          .join(', ');
      buf.write('TraceIds (${_traceIdOrder.length}): $parts');
      if (_traceIdOrder.length > maxTrace) {
        buf.write(' ... +${_traceIdOrder.length - maxTrace} more');
      }
      buf.writeln();
    }

    return buf.toString();
  }

  String getLogs(Map<String, dynamic> args) {
    final count = (args['count'] as int?) ?? 50;
    final levelStr = args['level'] as String?;
    final scopeFilter = args['scope'] as String?;
    final messageFilter = args['message'] as String?;
    final deviceFilter = args['device'] as String?;
    final traceIdFilter = args['traceId'] as String?;
    final typeFilter = args['type'] as String?;
    final sinceStr = args['since'] as String?;
    final afterCursor = args['cursor'] as int?;
    final collapse = (args['collapse'] as bool?) ?? false;
    final noData = (args['no_data'] as bool?) ?? false;
    final contextLines = ((args['context'] as int?) ?? 0).clamp(0, 20);

    final level = levelStr != null
        ? RpcLogLevel.values.where((l) => l.name == levelStr).firstOrNull
        : null;

    final limit = count.clamp(1, 500);

    // Resolve start index: cursor takes priority, then since
    int startIndex = 0;
    bool staleCursor = false;
    if (afterCursor != null) {
      final skip = _cursor - afterCursor;
      if (skip <= 0) {
        // Caller is up to date (or ahead): nothing new.
        startIndex = _records.length;
      } else if (skip < _records.length) {
        startIndex = _records.length - skip;
      } else {
        // skip >= retained window: the record after the cursor was evicted.
        // Return the full retained window but flag the gap so an incremental
        // tail consumer knows records were lost and can reset.
        staleCursor = true;
        startIndex = 0;
      }
    } else if (sinceStr != null) {
      final cutoff = _parseSince(sinceStr);
      if (cutoff != null) startIndex = _findSinceIndex(cutoff);
    }

    final filter = _Filter(
      level: level,
      scope: scopeFilter,
      message: messageFilter,
      device: deviceFilter,
      traceId: traceIdFilter,
      type: typeFilter,
    );

    final stalePrefix = staleCursor
        ? 'WARNING: cursor stale -- records after it were evicted; '
              'this is a reset, the window below may include already-seen records.\n'
        : '';

    if (contextLines > 0) {
      return stalePrefix +
          _getLogsWithContext(
            startIndex: startIndex,
            limit: limit,
            contextLines: contextLines,
            filter: filter,
            noData: noData,
          );
    }

    return stalePrefix +
        _getLogsSimple(
          startIndex: startIndex,
          limit: limit,
          filter: filter,
          collapse: collapse,
          noData: noData,
        );
  }

  // ---------------------------------------------------------------------------
  // Simple getLogs (no context)
  // ---------------------------------------------------------------------------

  String _getLogsSimple({
    required int startIndex,
    required int limit,
    required _Filter filter,
    required bool collapse,
    required bool noData,
  }) {
    // Iterate newest-first; collect limit+1 to detect hasMore without full scan
    final source =
        (startIndex == 0
                ? _records.toList()
                : _records.skip(startIndex).toList())
            .reversed;

    final matched = <TaggedRecord>[];
    bool hasMore = false;

    for (final tagged in source) {
      if (!filter.passes(tagged)) continue;
      if (matched.length >= limit) {
        hasMore = true;
        break;
      }
      matched.add(tagged);
    }

    if (matched.isEmpty) return 'No logs found. Cursor: $_cursor';

    final chronological = matched.reversed.toList();
    final lines = collapse
        ? _collapseRecords(chronological, noData: noData)
        : chronological
              .map((t) => _formatTaggedRecord(t, noData: noData))
              .toList();

    final countLabel = hasMore
        ? 'Showing ${matched.length} of ${matched.length}+ matching records (cursor: $_cursor)'
        : 'Found ${matched.length} records (cursor: $_cursor)';

    return '$countLabel:\n${lines.join('\n')}';
  }

  // ---------------------------------------------------------------------------
  // Context getLogs
  // ---------------------------------------------------------------------------

  /// Returns matching records with [contextLines] surrounding lines.
  ///
  /// Matching lines are prefixed with `>`, context lines with two spaces.
  /// Non-contiguous windows are separated by `---`.
  String _getLogsWithContext({
    required int startIndex,
    required int limit,
    required int contextLines,
    required _Filter filter,
    required bool noData,
  }) {
    // Find matching indices in chronological order within [startIndex, end)
    final matchIndices = <int>[];
    for (int i = startIndex; i < _records.length; i++) {
      if (!filter.passes(_records.elementAt(i))) continue;
      matchIndices.add(i);
      if (matchIndices.length >= limit) break;
    }

    if (matchIndices.isEmpty) return 'No logs found. Cursor: $_cursor';

    // Expand each match to a window [start, end] and merge overlapping ones
    final windows = <({int start, int end, Set<int> matches})>[];
    for (final idx in matchIndices) {
      final wStart = max(startIndex, idx - contextLines);
      final wEnd = min(_records.length - 1, idx + contextLines);

      if (windows.isNotEmpty && wStart <= windows.last.end + 1) {
        final last = windows.removeLast();
        windows.add((
          start: last.start,
          end: max(last.end, wEnd),
          matches: last.matches..add(idx),
        ));
      } else {
        windows.add((start: wStart, end: wEnd, matches: {idx}));
      }
    }

    final buf = StringBuffer(
      'Found ${matchIndices.length} records with context±$contextLines (cursor: $_cursor):\n',
    );

    for (int w = 0; w < windows.length; w++) {
      if (w > 0) buf.writeln('---');
      final window = windows[w];
      for (int i = window.start; i <= window.end; i++) {
        final tagged = _records.elementAt(i);
        if (tagged.record is LogSpanStart) continue;
        final line = _formatTaggedRecord(tagged, noData: noData);
        buf.writeln(window.matches.contains(i) ? '> $line' : '  $line');
      }
    }

    return buf.toString().trimRight();
  }

  // ---------------------------------------------------------------------------
  // Collapse -- period detection 1-3
  // ---------------------------------------------------------------------------

  List<String> _collapseRecords(
    List<TaggedRecord> records, {
    bool noData = false,
  }) {
    final lines = <String>[];
    int i = 0;

    while (i < records.length) {
      bool found = false;

      for (int p = 1; p <= 3; p++) {
        if (i + 2 * p > records.length) continue;

        bool patternMatches = true;
        for (int j = 0; j < p; j++) {
          if (_collapseKey(records[i + j]) !=
              _collapseKey(records[i + p + j])) {
            patternMatches = false;
            break;
          }
        }
        if (!patternMatches) continue;

        int reps = 1;
        while (i + (reps + 1) * p <= records.length) {
          bool nextMatches = true;
          for (int j = 0; j < p; j++) {
            if (_collapseKey(records[i + j]) !=
                _collapseKey(records[i + reps * p + j])) {
              nextMatches = false;
              break;
            }
          }
          if (!nextMatches) break;
          reps++;
        }

        if (p == 1) {
          lines.add(
            '[x$reps] ${_formatTaggedRecord(records[i], noData: noData)}',
          );
        } else {
          lines.add('[x$reps cycles]:');
          for (int j = 0; j < p; j++) {
            lines.add(
              '  ${_formatTaggedRecord(records[i + j], noData: noData)}',
            );
          }
        }

        i += reps * p;
        found = true;
        break;
      }

      if (!found) {
        lines.add(_formatTaggedRecord(records[i], noData: noData));
        i++;
      }
    }

    return lines;
  }

  String _collapseKey(TaggedRecord tagged) => switch (tagged.record) {
    LogEvent e => '${tagged.deviceLabel}|${e.scope}|${e.message}',
    LogSpan s => '${tagged.deviceLabel}|${s.scope}|${s.name}',
    LogSpanStart s => '${tagged.deviceLabel}|${s.scope}|start',
  };

  // ---------------------------------------------------------------------------
  // Formatting
  // ---------------------------------------------------------------------------

  String _formatTaggedRecord(TaggedRecord tagged, {bool noData = false}) {
    final device = tagged.deviceLabel;
    return switch (tagged.record) {
      LogSpanStart() => '',
      LogEvent event => _formatEvent(device, event, noData: noData),
      LogSpan span => _formatSpan(device, span),
    };
  }

  String _formatEvent(String device, LogEvent event, {bool noData = false}) {
    final sb = StringBuffer(
      '${_fmtTime(event.timestamp)} [$device] ${event.level.name.toUpperCase().padRight(5)} '
      '${event.scope}  ${event.message}',
    );
    if (event.error != null) sb.write('  err=${event.error}');
    if (event.traceId != null) sb.write('  trace=${event.traceId}');
    if (!noData && event.data != null && event.data!.isNotEmpty) {
      final dataStr = event.data!.entries
          .map((e) => '${e.key}=${e.value}')
          .join(' ');
      final truncated = dataStr.length > 120
          ? '${dataStr.substring(0, 120)}...'
          : dataStr;
      sb.write('  $truncated');
    }
    return sb.toString();
  }

  String _formatSpan(String device, LogSpan span) {
    final sb = StringBuffer(
      '${_fmtTime(span.endTime)} [$device] SPAN  ${span.scope}  ${span.name} '
      '${span.duration.inMilliseconds}ms ${span.status.name}',
    );
    if (span.error != null) sb.write('  err=${span.error}');
    if (span.traceId != null) sb.write('  trace=${span.traceId}');
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // Since helpers
  // ---------------------------------------------------------------------------

  /// Parses a `since` string into an absolute [DateTime] cutoff.
  ///
  /// Relative formats: `30s`, `2m`, `1h`
  /// Absolute formats: `14:55`, `14:55:30`
  static DateTime? _parseSince(String since) {
    // Relative
    final rel = RegExp(r'^(\d+)(s|m|h)$').firstMatch(since.trim());
    if (rel != null) {
      final value = int.parse(rel.group(1)!);
      final duration = switch (rel.group(2)!) {
        's' => Duration(seconds: value),
        'm' => Duration(minutes: value),
        'h' => Duration(hours: value),
        _ => Duration.zero,
      };
      return DateTime.now().subtract(duration);
    }

    // Absolute HH:MM or HH:MM:SS
    final abs = RegExp(
      r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$',
    ).firstMatch(since.trim());
    if (abs != null) {
      final now = DateTime.now();
      return DateTime(
        now.year,
        now.month,
        now.day,
        int.parse(abs.group(1)!),
        int.parse(abs.group(2)!),
        abs.group(3) != null ? int.parse(abs.group(3)!) : 0,
      );
    }

    return null;
  }

  /// Binary search for first record index with timestamp >= [cutoff]. O(log n).
  int _findSinceIndex(DateTime cutoff) {
    int lo = 0, hi = _records.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_records.elementAt(mid).record.timestamp.isBefore(cutoff)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

// ---------------------------------------------------------------------------
// Filter helper
// ---------------------------------------------------------------------------

class _Filter {
  final RpcLogLevel? level;
  final String? scope;
  final String? device;
  final String? traceId;
  final String? type;
  final RegExp? _messagePattern;

  _Filter({
    this.level,
    this.scope,
    this.device,
    this.traceId,
    this.type,
    String? message,
  }) : _messagePattern = _compilePattern(message);

  /// Compiles [pattern] as a case-insensitive regex.
  /// Falls back to escaped literal if the pattern is invalid regex.
  static RegExp? _compilePattern(String? pattern) {
    if (pattern == null || pattern.isEmpty) return null;
    try {
      return RegExp(pattern, caseSensitive: false);
    } catch (_) {
      return RegExp(RegExp.escape(pattern), caseSensitive: false);
    }
  }

  bool passes(TaggedRecord tagged) {
    final r = tagged.record;
    if (r is LogSpanStart) return false;

    if (device != null &&
        !tagged.deviceLabel.toLowerCase().contains(device!.toLowerCase())) {
      return false;
    }

    if (level != null && r is LogEvent && r.level < level!) return false;

    if (scope != null && !r.scope.startsWith(scope!)) return false;

    if (type == 'span' && r is! LogSpan) return false;
    if (type == 'event' && r is! LogEvent) return false;

    if (traceId != null) {
      final tid = r is LogEvent ? r.traceId : (r is LogSpan ? r.traceId : null);
      if (tid == null || !tid.startsWith(traceId!)) return false;
    }

    if (_messagePattern != null) {
      final target = switch (r) {
        LogEvent event => event.message,
        LogSpan span => span.name,
        _ => '',
      };
      if (!_messagePattern.hasMatch(target)) return false;
    }

    return true;
  }
}

// ---------------------------------------------------------------------------
// Scope stats
// ---------------------------------------------------------------------------

class _ScopeStats {
  int total = 0;
  int errors = 0;
  int warnings = 0;
  int spans = 0;

  void add(LogRecord r) {
    total++;
    if (r is LogEvent) {
      if (r.level == RpcLogLevel.error || r.level == RpcLogLevel.fatal) {
        errors++;
      }
      if (r.level == RpcLogLevel.warning) warnings++;
    }
    if (r is LogSpan) spans++;
  }

  @override
  String toString() {
    final parts = ['$total total'];
    if (errors > 0) parts.add('$errors err');
    if (warnings > 0) parts.add('$warnings warn');
    if (spans > 0) parts.add('$spans spans');
    return parts.join(', ');
  }
}
