// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'messages.dart';

/// Callback when a client completes handshake.
typedef OnHandshake = void Function(LogCollectorHandshake info);

/// Callback when a log record is received.
typedef OnLogRecord = void Function(LogCollectorRecord record);

/// Server-side contract that receives log records from remote clients.
class LogCollectorServiceResponder extends RpcResponderContract {
  final OnHandshake? _onHandshake;
  final OnLogRecord? _onRecord;

  LogCollectorServiceResponder({
    OnHandshake? onHandshake,
    OnLogRecord? onRecord,
  }) : _onHandshake = onHandshake,
       _onRecord = onRecord,
       super(
         'LogCollectorService',
         dataTransferMode: RpcDataTransferMode.codec,
       ) {
    addUnaryMethod<LogCollectorHandshake, LogCollectorWelcome>(
      methodName: 'handshake',
      handler: _handleHandshake,
      requestCodec: logCollectorHandshakeCodec,
      responseCodec: logCollectorWelcomeCodec,
    );
    addUnaryMethod<LogCollectorRecord, LogCollectorAck>(
      methodName: 'send',
      handler: _handleSend,
      requestCodec: logCollectorRecordCodec,
      responseCodec: logCollectorAckCodec,
    );
  }

  int _sessionId = 0;

  Future<LogCollectorWelcome> _handleHandshake(
    LogCollectorHandshake request, {
    RpcContext? context,
  }) async {
    _sessionId++;
    _onHandshake?.call(request);
    return LogCollectorWelcome(sessionId: _sessionId);
  }

  Future<LogCollectorAck> _handleSend(
    LogCollectorRecord request, {
    RpcContext? context,
  }) async {
    _onRecord?.call(request);
    return const LogCollectorAck();
  }
}
