// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

import 'messages.dart';

part 'log_collector_contract.g.dart';

/// The wire contract between a `LogCollectorOutput` and a collector.
@RpcService(
  name: 'LogCollectorService',
  transferMode: RpcDataTransferMode.codec,
)
abstract interface class ILogCollectorService implements IRpcContract {
  /// Identify this client to the collector.
  @RpcMethod.unary(name: 'handshake')
  Future<LogCollectorWelcome> handshake(
    LogCollectorHandshake request, {
    RpcContext? context,
  });

  /// Send a single log record.
  ///
  /// Unary on the wire, but `LogCollectorOutput` pipelines these calls: it
  /// issues the next `send` without awaiting the previous ack, so per-record
  /// RTT does not cap throughput, and it never blocks the logging hot path.
  /// The ack confirms delivery for the in-flight window (no loss on
  /// reconnect).
  @RpcMethod.unary(name: 'send')
  Future<LogCollectorAck> send(
    LogCollectorRecord request, {
    RpcContext? context,
  });
}

/// The collector side of [ILogCollectorService], forwarding each call to a
/// callback.
final class LogCollectorHandler extends LogCollectorServiceResponder {
  /// Answers a handshake with the session id it returns.
  final int Function(LogCollectorHandshake info) onHandshake;

  /// Receives every record.
  final void Function(LogCollectorRecord record) onRecord;

  LogCollectorHandler({required this.onHandshake, required this.onRecord});

  @override
  Future<LogCollectorWelcome> handshake(
    LogCollectorHandshake request, {
    RpcContext? context,
  }) async => LogCollectorWelcome(sessionId: onHandshake(request));

  @override
  Future<LogCollectorAck> send(
    LogCollectorRecord request, {
    RpcContext? context,
  }) async {
    onRecord(request);
    return const LogCollectorAck();
  }
}
