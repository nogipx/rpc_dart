// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'messages.dart';

/// Callback when a client completes handshake.
typedef OnHandshake = void Function(LogviewHandshake info);

/// Callback when a log record is received.
typedef OnLogRecord = void Function(LogviewRecord record);

/// Server-side contract that receives log records from remote clients.
class LogviewServiceResponder extends RpcResponderContract {
  final OnHandshake? _onHandshake;
  final OnLogRecord? _onRecord;

  LogviewServiceResponder({
    OnHandshake? onHandshake,
    OnLogRecord? onRecord,
  })  : _onHandshake = onHandshake,
        _onRecord = onRecord,
        super('LogviewService', dataTransferMode: RpcDataTransferMode.codec) {
    addUnaryMethod<LogviewHandshake, LogviewWelcome>(
      methodName: 'handshake',
      handler: _handleHandshake,
      requestCodec: logviewHandshakeCodec,
      responseCodec: logviewWelcomeCodec,
    );
    addUnaryMethod<LogviewRecord, LogviewAck>(
      methodName: 'send',
      handler: _handleSend,
      requestCodec: logviewRecordCodec,
      responseCodec: logviewAckCodec,
    );
  }

  int _sessionId = 0;

  Future<LogviewWelcome> _handleHandshake(
    LogviewHandshake request, {
    RpcContext? context,
  }) async {
    _sessionId++;
    _onHandshake?.call(request);
    return LogviewWelcome(sessionId: _sessionId);
  }

  Future<LogviewAck> _handleSend(
    LogviewRecord request, {
    RpcContext? context,
  }) async {
    _onRecord?.call(request);
    return const LogviewAck();
  }
}
