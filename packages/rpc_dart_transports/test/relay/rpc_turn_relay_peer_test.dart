// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';

/// Простой echo + count контракт для тестов
class EchoResponderContract extends RpcResponderContract {
  EchoResponderContract() : super('echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async => RpcString('echo:${request.value}'),
    );

    addServerStreamMethod<RpcInt, RpcInt>(
      methodName: 'countTo',
      requestCodec: RpcInt.codec,
      responseCodec: RpcInt.codec,
      handler: (request, {context}) {
        final total = request.value;
        return Stream<int>.periodic(
          const Duration(milliseconds: 50),
          (i) => i + 1,
        ).take(total).map(RpcInt.new);
      },
    );
  }
}

class PingResponderContract extends RpcResponderContract {
  PingResponderContract() : super('integration');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async {
        if (request.value != 'ping') {
          throw StateError('Unexpected payload: ${request.value}');
        }
        return RpcString('pong');
      },
    );
  }
}

void main() {
  group('RpcTurnRelayPeer', () {
    late TurnRelayServer server;
    final peers = <RpcTurnRelayPeer>[];

    setUp(() async {
      server = TurnRelayServer(
        bindAddress: InternetAddress.loopbackIPv4,
        bindPort: 0,
      );
      await server.start();
    });

    tearDown(() async {
      for (final p in peers) {
        try {
          await p.close();
        } catch (_) {}
      }
      peers.clear();
      await server.stop();
    });

    test('throws when accessing endpoints before connectPeer()', () async {
      final peer = await RpcTurnRelayPeer.connectToRelay(
        serverAddress: server.bindAddress,
        serverPort: server.port,
        responderContracts: [EchoResponderContract()],
      );
      peers.add(peer);

      expect(() => peer.callerEndpoint, throwsA(isA<StateError>()));
      expect(() => peer.responderEndpoint, throwsA(isA<StateError>()));
    });

    test('unary echo call A -> B', () async {
      final peerA = await RpcTurnRelayPeer.connectToRelay(
        serverAddress: server.bindAddress,
        serverPort: server.port,
        responderContracts: [EchoResponderContract()],
      );
      final peerB = await RpcTurnRelayPeer.connectToRelay(
        serverAddress: server.bindAddress,
        serverPort: server.port,
        responderContracts: [EchoResponderContract()],
      );
      peers.addAll([peerA, peerB]);

      // Обмениваемся адресами и инициируем peer соединение
      await peerA.connectPeer(
        peerAddress: peerB.relayAddress,
        peerPort: peerB.relayPort,
      );
      await peerB.connectPeer(
        peerAddress: peerA.relayAddress,
        peerPort: peerA.relayPort,
      );

      final response =
          await peerA.callerEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'echo',
        methodName: 'echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('ping'),
      );

      expect(response.value, 'echo:ping');
    });

    test('server stream countTo A -> B', () async {
      final peerA = await RpcTurnRelayPeer.connectToRelay(
        serverAddress: server.bindAddress,
        serverPort: server.port,
        responderContracts: [EchoResponderContract()],
      );
      final peerB = await RpcTurnRelayPeer.connectToRelay(
        serverAddress: server.bindAddress,
        serverPort: server.port,
        responderContracts: [EchoResponderContract()],
      );
      peers.addAll([peerA, peerB]);

      await peerA.connectPeer(
        peerAddress: peerB.relayAddress,
        peerPort: peerB.relayPort,
      );
      await peerB.connectPeer(
        peerAddress: peerA.relayAddress,
        peerPort: peerA.relayPort,
      );

      final values = await peerA.callerEndpoint
          .serverStream<RpcInt, RpcInt>(
            serviceName: 'echo',
            methodName: 'countTo',
            requestCodec: RpcInt.codec,
            responseCodec: RpcInt.codec,
            request: RpcInt(5),
          )
          .map((m) => m.value)
          .toList();

      expect(values, [1, 2, 3, 4, 5]);
    });

    test('bidirectional unary calls (A<->B)', () async {
      final peerA = await RpcTurnRelayPeer.connectToRelay(
        serverAddress: server.bindAddress,
        serverPort: server.port,
        responderContracts: [EchoResponderContract()],
      );
      final peerB = await RpcTurnRelayPeer.connectToRelay(
        serverAddress: server.bindAddress,
        serverPort: server.port,
        responderContracts: [EchoResponderContract()],
      );
      peers.addAll([peerA, peerB]);

      await peerA.connectPeer(
        peerAddress: peerB.relayAddress,
        peerPort: peerB.relayPort,
      );
      await peerB.connectPeer(
        peerAddress: peerA.relayAddress,
        peerPort: peerA.relayPort,
      );

      final respAB =
          await peerA.callerEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'echo',
        methodName: 'echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('fromA'),
      );
      final respBA =
          await peerB.callerEndpoint.unaryRequest<RpcString, RpcString>(
        serviceName: 'echo',
        methodName: 'echo',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: RpcString('fromB'),
      );

      expect(respAB.value, 'echo:fromA');
      expect(respBA.value, 'echo:fromB');
    });

    test('discovers peer via relay catalogue and exchanges ping/pong',
        () async {
      final peerA = await RpcTurnRelayPeer.connectToRelay(
        serverAddress: server.bindAddress,
        serverPort: server.port,
        responderContracts: [PingResponderContract()],
      );
      peers.add(peerA);

      const serviceId = 'integration.ping';
      await peerA.registerService(
        serviceId: serviceId,
        description: 'Peer A ping handler',
      );

      final peerB = await RpcTurnRelayPeer.connectToRelay(
        serverAddress: server.bindAddress,
        serverPort: server.port,
      );
      peers.add(peerB);

      TurnRelayServiceInfo? serviceInfo;
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (serviceInfo == null && DateTime.now().isBefore(deadline)) {
        final services = await peerB.listServices(serviceId: serviceId);
        if (services.isNotEmpty) {
          serviceInfo = services.single;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(serviceInfo, isNotNull, reason: 'service was not discovered');
      expect(serviceInfo!.serviceId, serviceId);
      expect(serviceInfo!.description, 'Peer A ping handler');
      expect(serviceInfo!.relayAddress.address, peerA.relayAddress.address);
      expect(serviceInfo!.relayPort, peerA.relayPort);

      await peerB.connectPeer(
        peerAddress: serviceInfo!.relayAddress,
        peerPort: serviceInfo!.relayPort,
      );

      await peerB.sendConnectionInfoToPeer(
        peerAddress: serviceInfo!.relayAddress,
        peerPort: serviceInfo!.relayPort,
      );

      final connectRequest = await peerA.connectRequests.first.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('peerA did not receive connect request'),
      );

      await peerA.connectPeer(
        peerAddress: connectRequest.peerAddress,
        peerPort: connectRequest.peerPort,
      );

      final response = await peerB.callerEndpoint
          .unaryRequest<RpcString, RpcString>(
        serviceName: 'integration',
        methodName: 'ping',
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        request: const RpcString('ping'),
      );

      expect(response.value, 'pong');
    });

    test('close is idempotent', () async {
      final peer = await RpcTurnRelayPeer.connectToRelay(
        serverAddress: server.bindAddress,
        serverPort: server.port,
        responderContracts: [EchoResponderContract()],
      );
      peers.add(peer);

      await peer.close();
      // Повторный close не должен бросать
      await peer.close();
    });
  });
}
