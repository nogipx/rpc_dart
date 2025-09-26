// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';

const _ioTimeout = Duration(seconds: 1);

void main() {
  group('TurnRelayClient', () {
    late TurnRelayServer server;

    setUp(() async {
      server = TurnRelayServer(
        bindAddress: InternetAddress.loopbackIPv4,
        bindPort: 0,
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('relays payload bytes via TURN (TCP peer)', () async {
      final client = await TurnRelayClient.connect(
        serverAddress: server.bindAddress,
        serverPort: server.port,
        options: const TurnRelayClientOptions(
          requestedTransport: TurnRequestedTransport.tcp,
        ),
      );
      addTearDown(client.close);

      expect(client.relayAddress, equals(server.relayAddress));
      expect(client.relayPort, greaterThan(0));

      final peerSocket =
          await Socket.connect(client.relayAddress, client.relayPort);
      addTearDown(peerSocket.close);

      final peerPayloads = StreamController<Uint8List>();
      final peerSub = peerSocket.listen((Uint8List data) {
        if (data.isNotEmpty) {
          peerPayloads.add(Uint8List.fromList(data));
        }
      });
      addTearDown(() async {
        await peerSub.cancel();
        await peerPayloads.close();
      });

      await client.addPermission(peerSocket.address, peerSocket.port);

      const outboundText = 'hello';
      final outboundPayload = Uint8List.fromList(outboundText.codeUnits);

      await client.send(
        outboundPayload,
        peerAddress: peerSocket.address,
        peerPort: peerSocket.port,
      );

      final peerReceived = await peerPayloads.stream.first.timeout(
        _ioTimeout,
        onTimeout: () => throw StateError('TCP peer timeout waiting outbound'),
      );
      expect(peerReceived, outboundPayload);

      const inboundText = 'world';
      final inboundPayload = Uint8List.fromList(inboundText.codeUnits);
      peerSocket.add(inboundPayload);

      final received = await _nextClientBytes(client);
      expect(received, inboundPayload);
    });

    test('delivers connect requests to the target allocation', () async {
      final initiator = await TurnRelayClient.connect(
        serverAddress: server.bindAddress,
        serverPort: server.port,
      );
      addTearDown(initiator.close);

      final target = await TurnRelayClient.connect(
        serverAddress: server.bindAddress,
        serverPort: server.port,
      );
      addTearDown(target.close);

      final payload = Uint8List.fromList(<int>[1, 2, 3]);
      final requestFuture = target.connectRequests.first.timeout(
        _ioTimeout,
        onTimeout: () =>
            throw StateError('Target allocation did not receive connect request'),
      );

      await initiator.requestPeerConnection(
        peerAddress: target.relayAddress,
        peerPort: target.relayPort,
        payload: payload,
      );

      final request = await requestFuture;
      expect(request.peerAddress.address, initiator.relayAddress.address);
      expect(request.peerPort, initiator.relayPort);
      expect(request.payload, isNotNull);
      expect(request.payload, orderedEquals(payload));
    });
  });
}

Future<Uint8List> _nextClientBytes(TurnRelayClient client) async {
  return client.bytes.first.timeout(
    _ioTimeout,
    onTimeout: () =>
        throw StateError('Client did not receive data within timeout'),
  );
}
