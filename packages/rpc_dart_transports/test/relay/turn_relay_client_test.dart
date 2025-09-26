// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

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
  });
}

Future<Uint8List> _nextClientBytes(TurnRelayClient client) async {
  return client.bytes.first.timeout(
    _ioTimeout,
    onTimeout: () =>
        throw StateError('Client did not receive data within timeout'),
  );
}
