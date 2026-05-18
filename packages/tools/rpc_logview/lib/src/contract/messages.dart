// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

/// Sent by the client to identify itself.
class LogviewHandshake implements IRpcSerializable {
  final String deviceName;
  final String app;
  final String? os;
  final String? appVersion;

  const LogviewHandshake({
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

  static LogviewHandshake fromJson(Map<String, dynamic> json) =>
      LogviewHandshake(
        deviceName: json['deviceName'] as String? ?? 'unknown',
        app: json['app'] as String? ?? 'unknown',
        os: json['os'] as String?,
        appVersion: json['appVersion'] as String?,
      );
}

/// Server response to a handshake.
class LogviewWelcome implements IRpcSerializable {
  final int sessionId;

  const LogviewWelcome({required this.sessionId});

  @override
  Map<String, dynamic> toJson() => {'sessionId': sessionId};

  static LogviewWelcome fromJson(Map<String, dynamic> json) =>
      LogviewWelcome(sessionId: json['sessionId'] as int? ?? 0);
}

// ---------------------------------------------------------------------------
// Log record transport
// ---------------------------------------------------------------------------

/// A serialized log record (event or span) sent from client to collector.
class LogviewRecord implements IRpcSerializable {
  final Map<String, dynamic> payload;

  const LogviewRecord(this.payload);

  @override
  Map<String, dynamic> toJson() => payload;

  static LogviewRecord fromJson(Map<String, dynamic> json) =>
      LogviewRecord(json);
}

/// Acknowledgement for a sent record.
class LogviewAck implements IRpcSerializable {
  const LogviewAck();

  @override
  Map<String, dynamic> toJson() => {};

  static LogviewAck fromJson(Map<String, dynamic> json) => const LogviewAck();
}

// ---------------------------------------------------------------------------
// Codecs
// ---------------------------------------------------------------------------

final logviewHandshakeCodec =
    RpcCodec<LogviewHandshake>.withDecoder(LogviewHandshake.fromJson);
final logviewWelcomeCodec =
    RpcCodec<LogviewWelcome>.withDecoder(LogviewWelcome.fromJson);
final logviewRecordCodec =
    RpcCodec<LogviewRecord>.withDecoder(LogviewRecord.fromJson);
final logviewAckCodec =
    RpcCodec<LogviewAck>.withDecoder(LogviewAck.fromJson);
