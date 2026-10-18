// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';

import 'log_server.dart';
import 'protocol.dart';

// ANSI color codes
const _reset = '\x1B[0m';
const _dim = '\x1B[2m';
const _bold = '\x1B[1m';
const _red = '\x1B[31m';
const _green = '\x1B[32m';
const _yellow = '\x1B[33m';
const _magenta = '\x1B[35m';
const _cyan = '\x1B[36m';
const _white = '\x1B[37m';

/// Every field printed here came from a remote device, so each one passes
/// through this before it reaches the terminal.
String _e(Object? value) => ConsoleOutput.escapeLine('$value');

/// Terminal renderer for logCollector. Prints tagged log records with device
/// labels and ANSI colors.
class LogCollectorConsole {
  final bool colored;
  final int _maxLabelWidth;
  final IOSink _sink;

  /// [sink] defaults to stdout. Use stderr when running alongside MCP.
  LogCollectorConsole({this.colored = true, IOSink? sink})
    : _maxLabelWidth = 20,
      _sink = sink ?? stdout;

  /// Print a connection event.
  void printConnection(LogCollectorConnectionEvent event) {
    final now = _formatTime(DateTime.now());
    switch (event) {
      case final DeviceConnected e:
        final name = _e(e.session.deviceName);
        final app = _e(e.session.app);
        if (colored) {
          _sink.writeln(
            '$_dim$now$_reset $_green+$_reset '
            '$_bold$name$_reset '
            '$_dim($app)$_reset',
          );
        } else {
          _sink.writeln('$now + $name ($app)');
        }
      case final DeviceDisconnected e:
        final name = _e(e.session.deviceName);
        if (colored) {
          _sink.writeln(
            '$_dim$now$_reset $_red-$_reset '
            '$_dim$name disconnected$_reset',
          );
        } else {
          _sink.writeln('$now - $name disconnected');
        }
    }
  }

  /// Print a tagged log record.
  void printRecord(TaggedRecord tagged) {
    final record = tagged.record;
    final label = _padLabel(_e(tagged.deviceLabel));

    switch (record) {
      case LogSpanStart():
        return; // skip transient span starts
      case final LogEvent event:
        _printEvent(label, event);
      case final LogSpan span:
        _printSpan(label, span);
    }
  }

  void _printEvent(String label, LogEvent event) {
    final time = _formatTime(event.timestamp);
    final level = _formatLevel(event.level);
    final scope = _e(event.scope);
    final msg = _e(event.message);
    final traceId = event.traceId;

    final buf = StringBuffer();
    if (colored) {
      buf.write('$_dim$time$_reset ');
      buf.write('$_cyan$label$_reset ');
      buf.write('$level ');
      buf.write('$_dim$scope$_reset ');
      buf.write(msg);

      if (traceId != null) {
        buf.write(
          ' $_dim${_e(traceId.substring(0, 8.clamp(0, traceId.length)))}$_reset',
        );
      }
      if (event.data != null && event.data!.isNotEmpty) {
        for (final entry in event.data!.entries) {
          buf.write(' $_dim${_e(entry.key)}=$_reset${_e(entry.value)}');
        }
      }
      if (event.error != null) {
        buf.write(' ${_red}err=$_reset${_e(event.error)}');
      }
    } else {
      buf.write(
        '$time $label ${event.level.name.toUpperCase().padRight(3)} $scope $msg',
      );
      if (traceId != null) buf.write(' trace=${_e(traceId)}');
      if (event.data != null) {
        for (final entry in event.data!.entries) {
          buf.write(' ${_e(entry.key)}=${_e(entry.value)}');
        }
      }
      if (event.error != null) buf.write(' err=${_e(event.error)}');
    }

    _sink.writeln(buf);
  }

  void _printSpan(String label, LogSpan span) {
    final time = _formatTime(span.endTime);
    final ms = span.duration.inMilliseconds;
    final status = span.status == SpanStatus.ok ? 'OK' : 'ERR';
    final scope = _e(span.scope);
    final name = _e(span.name);
    final error = span.error;

    if (colored) {
      final statusColor = span.status == SpanStatus.ok ? _green : _red;
      _sink.writeln(
        '$_dim$time$_reset '
        '$_cyan$label$_reset '
        '${_magenta}SPN$_reset '
        '$_dim$scope$_reset '
        '$name '
        '$_dim${ms}ms$_reset '
        '$statusColor$status$_reset'
        '${error != null ? ' ${_red}err=$_reset${_e(error)}' : ''}',
      );
    } else {
      _sink.writeln(
        '$time $label SPN $scope $name ${ms}ms $status'
        '${error != null ? ' err=${_e(error)}' : ''}',
      );
    }
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  String _formatLevel(RpcLogLevel level) {
    final name = switch (level) {
      RpcLogLevel.internal => 'INT',
      RpcLogLevel.trace => 'TRC',
      RpcLogLevel.debug => 'DBG',
      RpcLogLevel.info => 'INF',
      RpcLogLevel.warning => 'WRN',
      RpcLogLevel.error => 'ERR',
      RpcLogLevel.fatal => 'FTL',
    };
    if (!colored) return name.padRight(3);
    final color = switch (level) {
      RpcLogLevel.internal => _dim,
      RpcLogLevel.trace => _dim,
      RpcLogLevel.debug => _white,
      RpcLogLevel.info => _green,
      RpcLogLevel.warning => _yellow,
      RpcLogLevel.error => _red,
      RpcLogLevel.fatal => '$_bold$_red',
    };
    return '$color$name$_reset';
  }

  String _padLabel(String label) {
    if (label.length > _maxLabelWidth) {
      return '${label.substring(0, _maxLabelWidth - 1)}.';
    }
    return label.padRight(_maxLabelWidth);
  }
}
