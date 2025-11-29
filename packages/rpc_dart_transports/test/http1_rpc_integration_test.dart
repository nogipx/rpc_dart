// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';

void main() {
  group('HTTP/1.1 RPC Transport', () {
    late RpcHttp1Server server;
    late RpcHttp1CallerTransport transport;
    late RpcCallerEndpoint endpoint;

    setUpAll(() async {
      server = RpcHttp1Server.createWithContracts(
        host: 'localhost',
        port: 0,
        contracts: [EchoServiceContract()],
      );
      await server.start();

      transport = RpcHttp1CallerTransport.connect(
        Uri.parse('http://localhost:${server.port}'),
      );
      endpoint = RpcCallerEndpoint(transport: transport);
    });

    tearDownAll(() async {
      await endpoint.close();
      await server.stop();
    });

    test('unary RPC works over HTTP/1.1', () async {
      final response = await endpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'EchoService',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('Hello HTTP/1.1'),
      );

      expect(response.value, equals('EchoService: Hello HTTP/1.1'));
    });

    test('unary RPC handles large payloads', () async {
      const largeSize = 512 * 1024 * 12;
      final payload = String.fromCharCodes(
        List<int>.filled(largeSize, 0x61),
      );
      final response = await endpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'EchoService',
        methodName: 'Echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString(payload),
      );

      expect(response.value.length, equals(payload.length + 13));
      expect(response.value, startsWith('EchoService: '));
      expect(
        response.value.substring(13),
        equals(payload),
      );
    });

    test('non-unary RPC returns UNIMPLEMENTED', () async {
      final stream = endpoint.serverStream<RpcString, RpcString>(
        serviceName: 'EchoService',
        methodName: 'ServerStream',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('no stream'),
      );

      await expectLater(
        () => stream.toList(),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('HTTP/1.1 transport allows unary RPCs only'),
          ),
        ),
      );
    });
  });
}

final class EchoServiceContract extends RpcResponderContract {
  EchoServiceContract() : super('EchoService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {context}) async {
        return RpcString('EchoService: ${request.value}');
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'ServerStream',
      handler: (request, {context}) async* {
        for (var i = 0; i < 3; i++) {
          yield RpcString('stream $i: ${request.value}');
        }
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
