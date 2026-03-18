// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcEndpoint ping', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late RpcCallerEndpoint callerEndpoint;
    late RpcResponderEndpoint responderEndpoint;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      callerEndpoint = RpcCallerEndpoint(
        transport: clientTransport,
        debugLabel: 'caller-test',
      );

      responderEndpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'responder-test',
      );

      responderEndpoint.start();
    });

    tearDown(() async {
      await callerEndpoint.close();
      await responderEndpoint.close();
    });

    test('ping возвращает успешный ответ с метаданными', () async {
      final result = await callerEndpoint.ping();

      expect(result.roundTrip.isNegative, isFalse);
      expect(result.responderTimestamp, isNotNull);
      expect(
        result.responseHeaders[RpcHeaders.grpcStatus],
        equals(RpcStatus.ok.toString()),
      );
      expect(
        result.responseHeaders
            .containsKey(RpcEndpointPingProtocol.responseTimestampHeader),
        isTrue,
      );
      expect(result.responderTransportType, contains('RpcInMemoryTransport'));
    });

    test('ping включает debug label responder эндпоинта', () async {
      final result = await callerEndpoint.ping();

      expect(result.responderDebugLabel, equals('responder-test'));
    });
  });
}
