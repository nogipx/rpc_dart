// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'messages.dart';

/// Client-side contract for sending log records to a logCollector collector.
class LogCollectorServiceCaller extends RpcCallerContract {
  LogCollectorServiceCaller(RpcCallerEndpoint endpoint)
    : super(
        'LogCollectorService',
        endpoint,
        dataTransferMode: RpcDataTransferMode.codec,
      );

  /// Identify this client to the collector.
  Future<LogCollectorWelcome> handshake(LogCollectorHandshake info) =>
      callUnary<LogCollectorHandshake, LogCollectorWelcome>(
        methodName: 'handshake',
        request: info,
        requestCodec: logCollectorHandshakeCodec,
        responseCodec: logCollectorWelcomeCodec,
      );

  /// Send a single log record.
  ///
  /// Unary on the wire, but the redesigned client ([LogCollectorOutput])
  /// pipelines these calls: it issues the next `send` without awaiting the
  /// previous ack, so per-record RTT no longer caps throughput, and it never
  /// blocks the logging hot path. The ack confirms delivery for the in-flight
  /// window (no loss on reconnect).
  Future<LogCollectorAck> send(LogCollectorRecord record) =>
      callUnary<LogCollectorRecord, LogCollectorAck>(
        methodName: 'send',
        request: record,
        requestCodec: logCollectorRecordCodec,
        responseCodec: logCollectorAckCodec,
      );
}
