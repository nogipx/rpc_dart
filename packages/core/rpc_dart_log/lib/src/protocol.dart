// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Device information sent by the client during handshake.
class DeviceInfo {
  /// Human-readable device name (e.g. "iPhone 15 Pro", "Pixel 8").
  final String name;

  /// Application identifier (e.g. "com.example.myapp").
  final String app;

  /// Operating system (e.g. "iOS 18.1", "Android 15").
  final String? os;

  /// Application version (e.g. "1.2.0+42").
  final String? appVersion;

  const DeviceInfo({
    required this.name,
    required this.app,
    this.os,
    this.appVersion,
  });

  @override
  String toString() {
    final parts = [name, app];
    if (appVersion != null) parts.add('v$appVersion');
    if (os != null) parts.add(os!);
    return parts.join(' / ');
  }
}

/// Wraps a LogRecord with the device label for display.
class TaggedRecord {
  final String deviceLabel;
  final LogRecord record;

  const TaggedRecord({required this.deviceLabel, required this.record});
}

/// Deserialize a LogRecord from a JSON map received over the wire.
LogRecord? deserializeRecord(Map<String, dynamic> json) {
  final type = json['type'] as String?;
  if (type == 'span') return LogSpan.fromJson(json);
  if (type == 'event') return LogEvent.fromJson(json);
  return null;
}

/// [record] as the JSON it is sent and weighed as, or null for a span start,
/// which is neither.
Map<String, dynamic>? serializeRecord(LogRecord record) => switch (record) {
  final LogEvent event => event.toJson(),
  final LogSpan span => span.toJson(),
  LogSpanStart() => null,
};

/// Whether [record] is an event at error level or above.
bool isErrorRecord(LogRecord record) =>
    record is LogEvent && record.level >= RpcLogLevel.error;

/// [value] made safe to print: every field came from a remote device.
String escapeRemote(Object? value) => ConsoleOutput.escapeLine('$value');

/// [t] as `HH:MM:SS`, followed by `.mmm` with [millis].
String formatClock(DateTime t, {bool millis = false}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  return millis ? '$clock.${t.millisecond.toString().padLeft(3, '0')}' : clock;
}
