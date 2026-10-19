// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

/// Sent by the client to identify itself.
class LogCollectorHandshake implements IRpcSerializable {
  final String deviceName;
  final String app;
  final String? os;
  final String? appVersion;

  const LogCollectorHandshake({
    required this.deviceName,
    required this.app,
    this.os,
    this.appVersion,
  });

  @override
  Map<String, dynamic> toJson() => {
    'deviceName': deviceName,
    'app': app,
    if (os != null) 'os': os,
    if (appVersion != null) 'appVersion': appVersion,
  };

  factory LogCollectorHandshake.fromJson(Map<String, dynamic> json) =>
      LogCollectorHandshake(
        deviceName: json['deviceName'] as String? ?? 'unknown',
        app: json['app'] as String? ?? 'unknown',
        os: json['os'] as String?,
        appVersion: json['appVersion'] as String?,
      );
}

/// Server response to a handshake.
class LogCollectorWelcome implements IRpcSerializable {
  /// The collector's id for this connection. A repeated handshake on the same
  /// connection gets the same id.
  final int sessionId;

  const LogCollectorWelcome({required this.sessionId});

  @override
  Map<String, dynamic> toJson() => {'sessionId': sessionId};

  factory LogCollectorWelcome.fromJson(Map<String, dynamic> json) =>
      LogCollectorWelcome(sessionId: json['sessionId'] as int? ?? 0);
}

/// A serialized log record (event or span) sent from client to collector.
class LogCollectorRecord implements IRpcSerializable {
  final Map<String, dynamic> payload;

  const LogCollectorRecord(this.payload);

  @override
  Map<String, dynamic> toJson() => payload;

  factory LogCollectorRecord.fromJson(Map<String, dynamic> json) =>
      LogCollectorRecord(json);
}

/// Acknowledgement returned by the collector for a received record.
///
/// The client (`LogCollectorOutput`) pipelines `send` calls: it does not await
/// the ack before sending the next record. The ack advances the in-flight
/// window off the hot path and drops confirmed records from the buffer (no
/// loss on reconnect).
class LogCollectorAck implements IRpcSerializable {
  const LogCollectorAck();

  @override
  Map<String, dynamic> toJson() => const {};

  factory LogCollectorAck.fromJson(Map<String, dynamic> json) =>
      const LogCollectorAck();
}
