// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import '../log_level.dart';
import '../log_output.dart';
import '../log_record.dart';

/// Console output format.
enum ConsoleFormat {
  /// Human-readable with structure and indentation.
  pretty,

  /// One JSON object per line (machine-parseable).
  json,

  /// Single line per record (high-volume).
  compact,
}

/// Pretty-prints log records to stdout with optional ANSI colors.
class ConsoleOutput extends LogOutput {
  /// Whether to use ANSI color codes.
  final bool colored;

  /// Output format.
  final ConsoleFormat format;

  @override
  final String? scopeFilter;

  ConsoleOutput({
    this.colored = true,
    this.format = ConsoleFormat.pretty,
    this.scopeFilter,
  });

  @override
  void write(LogRecord record) {
    switch (format) {
      case ConsoleFormat.pretty:
        _writePretty(record);
      case ConsoleFormat.json:
        _writeJson(record);
      case ConsoleFormat.compact:
        _writeCompact(record);
    }
  }

  void _writePretty(LogRecord record) {
    switch (record) {
      case LogSpanStart start:
        _writePrettySpanStart(start);
      case LogEvent event:
        _writePrettyEvent(event);
      case LogSpan span:
        _writePrettySpan(span);
    }
  }

  void _writePrettySpanStart(LogSpanStart start) {
    final line =
        '[${_formatTime(start.timestamp)}] SPAN ${_shortId(start.spanId)} >> ${start.scope}.${start.name}';
    if (colored) {
      print('\x1B[36m$line\x1B[0m');
    } else {
      print(line);
    }
  }

  void _writePrettyEvent(LogEvent event) {
    final buf = StringBuffer();
    buf.write('[${_formatTime(event.timestamp)}] ');
    buf.write(_levelTag(event.level));
    if (event.spanId != null) buf.write(' ${_shortId(event.spanId!)}');
    if (event.scope.isNotEmpty) buf.write(' ${event.scope}');
    if (event.tag != null) buf.write(' [${event.tag}]');
    buf.write('  ${event.message}');

    // Structured fields: trace, request, data — logfmt style
    if (event.traceId != null) buf.write('  trace=${event.traceId}');
    _writeData(buf, event.data);

    if (event.error != null) buf.write('  err=${event.error}');

    final line = buf.toString();
    if (colored) {
      print('${_colorForLevel(event.level)}$line\x1B[0m');
    } else {
      print(line);
    }

    if (event.stackTrace != null) {
      print('  ${event.stackTrace}');
    }
  }

  void _writePrettySpan(LogSpan span) {
    final buf = StringBuffer();
    buf.write(
        '[${_formatTime(span.endTime)}] SPAN ${_shortId(span.spanId)} ${span.scope}.${span.name}');
    buf.write(' ${span.duration.inMilliseconds}ms');
    buf.write(span.status == SpanStatus.ok ? ' [ok]' : ' [ERROR]');

    if (span.traceId != null) buf.write('  trace=${span.traceId}');
    _writeData(buf, span.data);

    if (span.error != null) buf.write('  err=${span.error}');

    final line = buf.toString();
    if (colored) {
      final color = span.status == SpanStatus.ok ? '\x1B[36m' : '\x1B[31m';
      print('$color$line\x1B[0m');
    } else {
      print(line);
    }
  }

  String _shortId(String id) => id.length > 6 ? id.substring(0, 6) : id;

  void _writeData(StringBuffer buf, Map<String, Object>? data) {
    if (data == null || data.isEmpty) return;
    for (final entry in data.entries) {
      final value = entry.value;
      if (value is String && value.contains(' ')) {
        buf.write(' ${entry.key}="$value"');
      } else {
        buf.write(' ${entry.key}=$value');
      }
    }
  }

  void _writeJson(LogRecord record) {
    switch (record) {
      case LogSpanStart _:
        return; // span start is implicit in JSON (events carry spanId)
      case LogEvent event:
        print(_jsonEncode(event.toJson()));
      case LogSpan span:
        print(_jsonEncode(span.toJson()));
    }
  }

  void _writeCompact(LogRecord record) {
    switch (record) {
      case LogSpanStart _:
        return; // skip in compact mode
      case LogEvent event:
        final time = _formatTime(event.timestamp);
        final level = event.level.name.toUpperCase().substring(0, 3);
        print('$time $level ${event.scope}: ${event.message}');
      case LogSpan span:
        final time = _formatTime(span.endTime);
        final status = span.status == SpanStatus.ok ? 'OK' : 'ERR';
        print('$time SPN ${span.scope}.${span.name} '
            '${span.duration.inMilliseconds}ms $status');
    }
  }

  String _formatTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';

  String _levelTag(RpcLogLevel level) {
    return switch (level) {
      RpcLogLevel.internal => 'INTR',
      RpcLogLevel.trace => 'TRCE',
      RpcLogLevel.debug => 'DEBG',
      RpcLogLevel.info => 'INFO',
      RpcLogLevel.warning => 'WARN',
      RpcLogLevel.error => 'ERRO',
      RpcLogLevel.fatal => 'FATL',
    };
  }

  String _colorForLevel(RpcLogLevel level) {
    return switch (level) {
      RpcLogLevel.internal => '\x1B[90m', // gray
      RpcLogLevel.trace => '\x1B[37m', // white
      RpcLogLevel.debug => '\x1B[36m', // cyan
      RpcLogLevel.info => '\x1B[32m', // green
      RpcLogLevel.warning => '\x1B[33m', // yellow
      RpcLogLevel.error => '\x1B[31m', // red
      RpcLogLevel.fatal => '\x1B[35m', // magenta
    };
  }

  String _jsonEncode(Map<String, dynamic> map) {
    // Simple JSON encoding without dart:convert dependency on formatting
    final buf = StringBuffer('{');
    var first = true;
    for (final entry in map.entries) {
      if (!first) buf.write(',');
      first = false;
      buf.write('"${entry.key}":');
      _writeJsonValue(buf, entry.value);
    }
    buf.write('}');
    return buf.toString();
  }

  void _writeJsonValue(StringBuffer buf, Object? value) {
    if (value == null) {
      buf.write('null');
    } else if (value is String) {
      buf.write('"${value.replaceAll('"', '\\"').replaceAll('\n', '\\n')}"');
    } else if (value is num || value is bool) {
      buf.write(value);
    } else if (value is Map) {
      buf.write('{');
      var first = true;
      for (final e in value.entries) {
        if (!first) buf.write(',');
        first = false;
        buf.write('"${e.key}":');
        _writeJsonValue(buf, e.value);
      }
      buf.write('}');
    } else if (value is List) {
      buf.write('[');
      for (var i = 0; i < value.length; i++) {
        if (i > 0) buf.write(',');
        _writeJsonValue(buf, value[i]);
      }
      buf.write(']');
    } else {
      buf.write('"$value"');
    }
  }
}
