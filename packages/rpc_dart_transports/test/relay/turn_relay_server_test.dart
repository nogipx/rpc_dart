// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:rpc_dart_transports/src/transports/relay/turn_tcp_frame.dart';
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

    for (final entry in [
      // ('udp', TurnRequestedTransport.udp),
      ('tcp', TurnRequestedTransport.tcp),
    ]) {
      final label = entry.$1;
      final requestedTransport = entry.$2;

      test('relays data between client and peer ($label)', () async {
        RawDatagramSocket? udpPeer;
        StreamSubscription<RawSocketEvent>? udpSub;
        StreamController<Datagram>? udpDatagrams;

        Socket? tcpPeer;
        StreamSubscription<Uint8List>? tcpPeerSub;
        final tcpPayloads = StreamController<Uint8List>();

        addTearDown(() async {
          await udpSub?.cancel();
          await udpDatagrams?.close();
          udpPeer?.close();

          await tcpPeerSub?.cancel();
          await tcpPayloads.close();
          await tcpPeer?.close();
        });

        final socket = await Socket.connect(server.bindAddress, server.port);
        final turnMessages = StreamController<TurnMessage>.broadcast();
        final frameDecoder = TurnTcpFrameDecoder(
          onTurnMessage: turnMessages.add,
          onChannelData: (_, __) {},
        );

        final socketSub = socket.listen(
          (Uint8List data) {
            if (data.isNotEmpty) {
              frameDecoder.addChunk(data);
            }
          },
        );

        addTearDown(() async {
          await socketSub.cancel();
          await turnMessages.close();
          await socket.close();
        });

        final allocateRequest = TurnMessage(
          method: TurnMethod.allocate,
          messageClass: TurnMessageClass.request,
          attributes: [
            TurnAttribute(
              TurnAttributeType.requestedTransport,
              Uint8List.fromList(<int>[requestedTransport, 0, 0, 0]),
            ),
          ],
        );

        socket.add(allocateRequest.encode());

        final allocateResponse = await turnMessages.stream.first.timeout(
          const Duration(seconds: 1),
          onTimeout: () => throw StateError('allocate response timeout'),
        );
        expect(allocateResponse.messageClass, TurnMessageClass.successResponse);
        expect(allocateResponse.method, TurnMethod.allocate);

        final relayedAttr = allocateResponse
            .firstAttribute(TurnAttributeType.xorRelayedAddress);
        expect(relayedAttr, isNotNull);
        final (relayAddress, relayPort) =
            decodeXorAddress(relayedAttr!, allocateResponse.transactionId);

        late final InternetAddress peerAddress;
        late final int peerPort;

        if (requestedTransport == TurnRequestedTransport.udp) {
          udpPeer = await RawDatagramSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          udpDatagrams = StreamController<Datagram>();
          udpSub = udpPeer.listen((event) {
            if (event == RawSocketEvent.read) {
              Datagram? datagram;
              while ((datagram = udpPeer!.receive()) != null) {
                udpDatagrams!.add(datagram!);
              }
            }
          });

          peerAddress = InternetAddress.loopbackIPv4;
          peerPort = udpPeer.port;
        } else {
          tcpPeer = await Socket.connect(relayAddress, relayPort);
          tcpPeerSub = tcpPeer.listen((Uint8List data) {
            if (data.isNotEmpty) {
              tcpPayloads.add(Uint8List.fromList(data));
            }
          });

          peerAddress = tcpPeer.address;
          peerPort = tcpPeer.port;
        }

        final permissionTx = TurnMessage.generateTransactionId();
        final permissionRequest = TurnMessage(
          method: TurnMethod.createPermission,
          messageClass: TurnMessageClass.request,
          transactionId: permissionTx,
          attributes: [
            TurnAttribute(
              TurnAttributeType.xorPeerAddress,
              encodeXorAddress(
                peerAddress,
                peerPort,
                permissionTx,
              ),
            ),
          ],
        );

        socket.add(permissionRequest.encode());

        final permissionResponse = await turnMessages.stream.first.timeout(
          const Duration(seconds: 1),
          onTimeout: () => throw StateError('permission response timeout'),
        );
        expect(
            permissionResponse.messageClass, TurnMessageClass.successResponse);
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
                peerAddress,
                peerPort,
                sendTx,
              ),
            ),
            TurnAttribute(TurnAttributeType.data, encodeData(outboundPayload)),
          ],
        );

        socket.add(sendIndication.encode());

        if (requestedTransport == TurnRequestedTransport.udp) {
          final peerDatagram = await udpDatagrams!.stream.first.timeout(
            const Duration(seconds: 1),
            onTimeout: () => throw StateError('peer did not receive data'),
          );
          expect(peerDatagram.data, outboundPayload);
          expect(peerDatagram.address, relayAddress);
          expect(peerDatagram.port, relayPort);

          final inboundPayload = Uint8List.fromList('pong'.codeUnits);
          udpPeer!.send(inboundPayload, relayAddress, relayPort);

          final dataIndication = await turnMessages.stream.first.timeout(
            const Duration(seconds: 1),
            onTimeout: () => throw StateError('client did not receive data'),
          );
          expect(dataIndication.messageClass, TurnMessageClass.indication);
          expect(dataIndication.method, TurnMethod.data);
          final dataAttr =
              dataIndication.firstAttribute(TurnAttributeType.data);
          expect(dataAttr, isNotNull);
          expect(dataAttr, inboundPayload);
        } else {
          final peerPayload = await tcpPayloads.stream.first.timeout(
            const Duration(seconds: 1),
            onTimeout: () => throw StateError('peer did not receive data'),
          );
          expect(peerPayload, outboundPayload);

          final inboundPayload = Uint8List.fromList('pong'.codeUnits);
          tcpPeer!.add(inboundPayload);

          final dataIndication = await turnMessages.stream.first.timeout(
            const Duration(seconds: 1),
            onTimeout: () => throw StateError('client did not receive data'),
          );
          expect(dataIndication.messageClass, TurnMessageClass.indication);
          expect(dataIndication.method, TurnMethod.data);
          final dataAttr =
              dataIndication.firstAttribute(TurnAttributeType.data);
          expect(dataAttr, isNotNull);
          expect(dataAttr, inboundPayload);
        }
      });
    }
  });
}
