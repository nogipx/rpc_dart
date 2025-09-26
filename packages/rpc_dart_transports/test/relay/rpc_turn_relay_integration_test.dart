// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';

final class _EchoResponderContract extends RpcResponderContract {
  _EchoResponderContract() : super('EchoService', dataTransferMode: RpcDataTransferMode.codec);

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {context}) async => RpcString('Echo:${request.value}'),
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}

final class _EchoCallerContract extends RpcCallerContract {
  _EchoCallerContract(RpcCallerEndpoint endpoint)
      : super('EchoService', endpoint, dataTransferMode: RpcDataTransferMode.codec);

  Future<RpcString> echo(String value) {
    return callUnary<RpcString, RpcString>(
      methodName: 'Echo',
      request: RpcString(value),
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}

void main() {
  group('TURN relay RPC integration', () {
    late RpcTurnRelayServer server;
    late RpcTurnRelayCallerTransport callerTransport;
    late RpcCallerEndpoint callerEndpoint;
    late _EchoCallerContract caller;

    setUp(() async {
      server = RpcTurnRelayServer(
        bindAddress: InternetAddress.loopbackIPv4,
        bindPort: 0,
        contracts: [_EchoResponderContract()],
      );
      await server.start();

      callerTransport = await RpcTurnRelayCallerTransport.connect(
        serverAddress: InternetAddress.loopbackIPv4,
        serverPort: server.port,
      );

      callerEndpoint = RpcCallerEndpoint(
        transport: callerTransport,
        debugLabel: 'turn-caller',
        loggerColors: RpcLoggerColors.singleColor(AnsiColor.green),
      );

      caller = _EchoCallerContract(callerEndpoint);
    });

    tearDown(() async {
      await callerEndpoint.close();
      await callerTransport.close();
      await server.stop();
    });

    test('performs unary RPC call through TURN relay', () async {
      final response = await caller.echo('ping');
      expect(response.value, equals('Echo:ping'));
    });
  });
}

