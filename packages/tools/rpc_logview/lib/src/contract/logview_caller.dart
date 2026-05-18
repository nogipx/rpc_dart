// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'messages.dart';

/// Client-side contract for sending log records to a logview collector.
class LogviewServiceCaller extends RpcCallerContract {
  LogviewServiceCaller(RpcCallerEndpoint endpoint)
      : super('LogviewService', endpoint,
            dataTransferMode: RpcDataTransferMode.codec);

  /// Identify this client to the collector.
  Future<LogviewWelcome> handshake(LogviewHandshake info) =>
      callUnary<LogviewHandshake, LogviewWelcome>(
        methodName: 'handshake',
        request: info,
        requestCodec: logviewHandshakeCodec,
        responseCodec: logviewWelcomeCodec,
      );

  /// Send a single log record. Call with unawaited() for fire-and-forget.
  Future<LogviewAck> send(LogviewRecord record) =>
      callUnary<LogviewRecord, LogviewAck>(
        methodName: 'send',
        request: record,
        requestCodec: logviewRecordCodec,
        responseCodec: logviewAckCodec,
      );
}
