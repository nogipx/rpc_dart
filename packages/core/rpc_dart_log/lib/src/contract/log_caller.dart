// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'messages.dart';

/// Client-side contract for sending log records to a logCollector collector.
class LogCollectorServiceCaller extends RpcCallerContract {
  LogCollectorServiceCaller(RpcCallerEndpoint endpoint)
      : super('LogCollectorService', endpoint,
            dataTransferMode: RpcDataTransferMode.codec);

  /// Identify this client to the collector.
  Future<LogCollectorWelcome> handshake(LogCollectorHandshake info) =>
      callUnary<LogCollectorHandshake, LogCollectorWelcome>(
        methodName: 'handshake',
        request: info,
        requestCodec: logCollectorHandshakeCodec,
        responseCodec: logCollectorWelcomeCodec,
      );

  /// Send a single log record. Call with unawaited() for fire-and-forget.
  Future<LogCollectorAck> send(LogCollectorRecord record) =>
      callUnary<LogCollectorRecord, LogCollectorAck>(
        methodName: 'send',
        request: record,
        requestCodec: logCollectorRecordCodec,
        responseCodec: logCollectorAckCodec,
      );
}
