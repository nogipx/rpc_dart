// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

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

  static LogCollectorHandshake fromJson(Map<String, dynamic> json) =>
      LogCollectorHandshake(
        deviceName: json['deviceName'] as String? ?? 'unknown',
        app: json['app'] as String? ?? 'unknown',
        os: json['os'] as String?,
        appVersion: json['appVersion'] as String?,
      );
}

/// Server response to a handshake.
class LogCollectorWelcome implements IRpcSerializable {
  final int sessionId;

  const LogCollectorWelcome({required this.sessionId});

  @override
  Map<String, dynamic> toJson() => {'sessionId': sessionId};

  static LogCollectorWelcome fromJson(Map<String, dynamic> json) =>
      LogCollectorWelcome(sessionId: json['sessionId'] as int? ?? 0);
}

// ---------------------------------------------------------------------------
// Log record transport
// ---------------------------------------------------------------------------

/// A serialized log record (event or span) sent from client to collector.
class LogCollectorRecord implements IRpcSerializable {
  final Map<String, dynamic> payload;

  const LogCollectorRecord(this.payload);

  @override
  Map<String, dynamic> toJson() => payload;

  static LogCollectorRecord fromJson(Map<String, dynamic> json) =>
      LogCollectorRecord(json);
}

/// Acknowledgement returned by the collector for a received record.
///
/// The client ([LogCollectorOutput]) pipelines `send` calls: it does not await
/// the ack before sending the next record, so per-record RTT no longer caps
/// throughput. The ack is still used off the hot path to advance the in-flight
/// window and drop confirmed records from the buffer (no loss on reconnect).
class LogCollectorAck implements IRpcSerializable {
  const LogCollectorAck();

  @override
  Map<String, dynamic> toJson() => const {};

  static LogCollectorAck fromJson(Map<String, dynamic> json) =>
      const LogCollectorAck();
}

// ---------------------------------------------------------------------------
// Codecs
// ---------------------------------------------------------------------------

final logCollectorHandshakeCodec = RpcCodec<LogCollectorHandshake>.withDecoder(
  LogCollectorHandshake.fromJson,
);
final logCollectorWelcomeCodec = RpcCodec<LogCollectorWelcome>.withDecoder(
  LogCollectorWelcome.fromJson,
);
final logCollectorRecordCodec = RpcCodec<LogCollectorRecord>.withDecoder(
  LogCollectorRecord.fromJson,
);
final logCollectorAckCodec = RpcCodec<LogCollectorAck>.withDecoder(
  LogCollectorAck.fromJson,
);
