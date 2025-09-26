// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';

void main() {
  group('TurnRelayServer', () {
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

    test('relays data between client and peer', () async {
      final clientSocket =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peerSocket =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);

      final clientDatagrams = StreamController<Datagram>();
      final peerDatagrams = StreamController<Datagram>();

      final clientSub = clientSocket.listen((event) {
        if (event == RawSocketEvent.read) {
          Datagram? datagram;
          while ((datagram = clientSocket.receive()) != null) {
            clientDatagrams.add(datagram!);
          }
        }
      });

      final peerSub = peerSocket.listen((event) {
        if (event == RawSocketEvent.read) {
          Datagram? datagram;
          while ((datagram = peerSocket.receive()) != null) {
            peerDatagrams.add(datagram!);
          }
        }
      });

      addTearDown(() async {
        await clientSub.cancel();
        await peerSub.cancel();
        await clientDatagrams.close();
        await peerDatagrams.close();
        clientSocket.close();
        peerSocket.close();
      });

      final serverAddress = server.bindAddress;
      final serverPort = server.port;

      final allocateRequest = TurnMessage(
        method: TurnMethod.allocate,
        messageClass: TurnMessageClass.request,
      );

      clientSocket.send(
        allocateRequest.encode(),
        serverAddress,
        serverPort,
      );

      final allocateResponse = await _nextTurnMessage(clientDatagrams.stream);
      expect(allocateResponse.messageClass, TurnMessageClass.successResponse);
      expect(allocateResponse.method, TurnMethod.allocate);

      final relayedAttr =
          allocateResponse.firstAttribute(TurnAttributeType.xorRelayedAddress);
      expect(relayedAttr, isNotNull);
      final (relayAddress, relayPort) =
          decodeXorAddress(relayedAttr!, allocateResponse.transactionId);

      final permissionTx = TurnMessage.generateTransactionId();
      final permissionRequest = TurnMessage(
        method: TurnMethod.createPermission,
        messageClass: TurnMessageClass.request,
        transactionId: permissionTx,
        attributes: [
          TurnAttribute(
            TurnAttributeType.xorPeerAddress,
            encodeXorAddress(
              InternetAddress.loopbackIPv4,
              peerSocket.port,
              permissionTx,
            ),
          ),
        ],
      );

      clientSocket.send(
        permissionRequest.encode(),
        serverAddress,
        serverPort,
      );

      final permissionResponse = await _nextTurnMessage(clientDatagrams.stream);
      expect(permissionResponse.messageClass, TurnMessageClass.successResponse);
      expect(permissionResponse.method, TurnMethod.createPermission);

      final outboundPayload = Uint8List.fromList('ping'.codeUnits);
      final sendTx = TurnMessage.generateTransactionId();
      final sendIndication = TurnMessage(
        method: TurnMethod.send,
        messageClass: TurnMessageClass.indication,
        transactionId: sendTx,
        attributes: [
          TurnAttribute(
            TurnAttributeType.xorPeerAddress,
            encodeXorAddress(
              InternetAddress.loopbackIPv4,
              peerSocket.port,
              sendTx,
            ),
          ),
          TurnAttribute(TurnAttributeType.data, encodeData(outboundPayload)),
        ],
      );

      clientSocket.send(
        sendIndication.encode(),
        serverAddress,
        serverPort,
      );

      final peerDatagram = await peerDatagrams.stream.first.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw StateError('peer did not receive data'),
      );
      expect(peerDatagram.data, outboundPayload);
      expect(peerDatagram.address, relayAddress);
      expect(peerDatagram.port, relayPort);

      final inboundPayload = Uint8List.fromList('pong'.codeUnits);
      peerSocket.send(inboundPayload, relayAddress, relayPort);

      final dataIndication = await _nextTurnMessage(clientDatagrams.stream);
      expect(dataIndication.messageClass, TurnMessageClass.indication);
      expect(dataIndication.method, TurnMethod.data);
      final dataAttr = dataIndication.firstAttribute(TurnAttributeType.data);
      expect(dataAttr, isNotNull);
      expect(dataAttr, inboundPayload);
    });
  });
}

Future<TurnMessage> _nextTurnMessage(Stream<Datagram> datagrams) async {
  await for (final datagram in datagrams) {
    final message =
        TurnMessage.decode(Uint8List.fromList(datagram.data));
    if (message != null) {
      return message;
    }
  }
  throw StateError('stream completed before receiving TURN message');
}
