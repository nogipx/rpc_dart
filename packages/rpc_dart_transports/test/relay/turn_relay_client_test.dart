// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';

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

    test('relays payload bytes via TURN', () async {
      final peerSocket =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(peerSocket.close);

      final client = await TurnRelayClient.connect(
        serverAddress: server.bindAddress,
        serverPort: server.port,
      );
      addTearDown(client.close);

      await client.addPermission(InternetAddress.loopbackIPv4, peerSocket.port);

      final outboundPayload = Uint8List.fromList('hello'.codeUnits);

      await client.send(
        outboundPayload,
        peerAddress: InternetAddress.loopbackIPv4,
        peerPort: peerSocket.port,
      );

      final peerReceived = await _nextPeerDatagram(peerSocket);
      expect(peerReceived.data, outboundPayload);
      expect(peerReceived.address, server.relayAddress);
      expect(peerReceived.port, server.allocations.first.relayPort);

      final inboundPayload = Uint8List.fromList('world'.codeUnits);
      peerSocket.send(inboundPayload, client.relayAddress, client.relayPort);

      final received = await client.bytes.first.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw StateError('client did not receive data'),
      );

      expect(received, inboundPayload);
    });
  });
}

Future<Datagram> _nextPeerDatagram(RawDatagramSocket socket) async {
  final completer = Completer<Datagram>();
  late StreamSubscription<RawSocketEvent> subscription;
  subscription = socket.listen((event) {
    if (event == RawSocketEvent.read) {
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        if (!completer.isCompleted) {
          completer.complete(datagram!);
        }
      }
    }
  });

  try {
    return await completer.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () => throw StateError('peer did not receive data'),
    );
  } finally {
    await subscription.cancel();
  }
}
