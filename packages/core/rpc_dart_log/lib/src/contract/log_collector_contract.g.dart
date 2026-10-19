// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'log_collector_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class LogCollectorServiceNames {
  const LogCollectorServiceNames._();
  static const service = 'LogCollectorService';
  static String instance(String suffix) => '$service\_$suffix';
  static const handshake = 'handshake';
  static const send = 'send';
}

class LogCollectorServiceCodecs {
  const LogCollectorServiceCodecs._();
  static const codecLogCollectorAck = RpcCodec<LogCollectorAck>(
    LogCollectorAck.fromJson,
  );
  static const codecLogCollectorHandshake = RpcCodec<LogCollectorHandshake>(
    LogCollectorHandshake.fromJson,
  );
  static const codecLogCollectorRecord = RpcCodec<LogCollectorRecord>(
    LogCollectorRecord.fromJson,
  );
  static const codecLogCollectorWelcome = RpcCodec<LogCollectorWelcome>(
    LogCollectorWelcome.fromJson,
  );
}

class LogCollectorServiceCaller extends RpcCallerContract
    implements ILogCollectorService {
  LogCollectorServiceCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? LogCollectorServiceNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<LogCollectorWelcome> handshake(
    LogCollectorHandshake request, {
    RpcContext? context,
  }) {
    return callUnary<LogCollectorHandshake, LogCollectorWelcome>(
      methodName: LogCollectorServiceNames.handshake,
      requestCodec: LogCollectorServiceCodecs.codecLogCollectorHandshake,
      responseCodec: LogCollectorServiceCodecs.codecLogCollectorWelcome,
      request: request,
      context: context,
    );
  }

  @override
  Future<LogCollectorAck> send(
    LogCollectorRecord request, {
    RpcContext? context,
  }) {
    return callUnary<LogCollectorRecord, LogCollectorAck>(
      methodName: LogCollectorServiceNames.send,
      requestCodec: LogCollectorServiceCodecs.codecLogCollectorRecord,
      responseCodec: LogCollectorServiceCodecs.codecLogCollectorAck,
      request: request,
      context: context,
    );
  }
}

abstract class LogCollectorServiceResponder extends RpcResponderContract
    implements ILogCollectorService {
  LogCollectorServiceResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? LogCollectorServiceNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<LogCollectorHandshake, LogCollectorWelcome>(
      methodName: LogCollectorServiceNames.handshake,
      handler: handshake,
      requestCodec: LogCollectorServiceCodecs.codecLogCollectorHandshake,
      responseCodec: LogCollectorServiceCodecs.codecLogCollectorWelcome,
    );
    addUnaryMethod<LogCollectorRecord, LogCollectorAck>(
      methodName: LogCollectorServiceNames.send,
      handler: send,
      requestCodec: LogCollectorServiceCodecs.codecLogCollectorRecord,
      responseCodec: LogCollectorServiceCodecs.codecLogCollectorAck,
    );
  }
}
