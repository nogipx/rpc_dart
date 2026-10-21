// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The ping protocol is off the public barrel; tests reach it here.
import 'package:rpc_dart/src/_internal.dart';
import 'package:test/test.dart';

void main() {
  group('RpcEndpoint ping', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late RpcCallerEndpoint callerEndpoint;
    late RpcResponderEndpoint responderEndpoint;

    setUp(() {
      final pair = RpcChannelTransport.memoryPair();
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

    test('ping answers successfully, with metadata', () async {
      final result = await callerEndpoint.ping();

      expect(result.roundTrip.isNegative, isFalse);
      expect(result.responderTimestamp, isNotNull);
      expect(result.responderTimestamp!.isUtc, isTrue);
      expect(
        result.responderTimestamp!.difference(DateTime.now().toUtc()).abs(),
        lessThan(const Duration(minutes: 1)),
      );
      expect(
        result.responseHeaders[RpcHeaders.grpcStatus],
        equals(RpcStatus.ok.code.toString()),
      );
      expect(
        result.responseHeaders.containsKey(
          RpcEndpointPingProtocol.responseTimestampHeader,
        ),
        isTrue,
      );
    });

    test('the answer is one trailer: no response headers before it', () async {
      final (client, server) = RpcChannelTransport.pair();
      final responder = RpcResponderEndpoint(transport: server)..start();
      addTearDown(() async {
        await responder.close();
        await client.close();
      });

      final id = client.createStream();
      final frames = client.getMessagesForStream(id).toList();
      await client.sendMetadata(
        id,
        RpcMetadata.forClientRequest(
          RpcEndpointPingProtocol.serviceName,
          RpcEndpointPingProtocol.methodName,
        ),
        endStream: true,
      );
      final received = await frames.timeout(const Duration(seconds: 5));

      expect(received, hasLength(1));
      expect(received.single.isEndOfStream, isTrue);
      expect(
        received.single.metadata?.getHeaderValue(RpcHeaders.grpcStatus),
        '0',
      );
    });

    test("ping carries the responder endpoint's debug label", () async {
      final result = await callerEndpoint.ping();

      expect(result.responderDebugLabel, equals('responder-test'));
    });
  });
}
