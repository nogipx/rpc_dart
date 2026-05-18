// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Protocol version. Checked during handshake.
const logviewProtocolVersion = 1;

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

  Map<String, dynamic> toJson() => {
        'name': name,
        'app': app,
        if (os != null) 'os': os,
        if (appVersion != null) 'appVersion': appVersion,
      };

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        name: json['name'] as String? ?? 'unknown',
        app: json['app'] as String? ?? 'unknown',
        os: json['os'] as String?,
        appVersion: json['appVersion'] as String?,
      );

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
/// Returns null if the map is not a recognized record type.
LogRecord? deserializeRecord(Map<String, dynamic> json) {
  final type = json['type'] as String?;
  if (type == 'span') {
    return LogSpan.fromJson(json);
  } else if (type == 'event') {
    return LogEvent.fromJson(json);
  }
  return null;
}

/// Serialize a LogRecord to a JSON map for sending over the wire.
/// Returns null for LogSpanStart (transient, not sent remotely).
Map<String, dynamic>? serializeRecord(LogRecord record) {
  return switch (record) {
    LogSpanStart() => null,
    LogEvent event => event.toJson(),
    LogSpan span => span.toJson(),
  };
}
