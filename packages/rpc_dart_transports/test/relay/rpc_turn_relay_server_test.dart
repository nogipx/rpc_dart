import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';
import 'package:universal_io/io.dart';

Future<Datagram> _nextDatagram(RawDatagramSocket socket) async {
  await for (final event in socket) {
    if (event == RawSocketEvent.read) {
      final datagram = socket.receive();
      if (datagram != null) {
        return datagram;
      }
    }
  }
  throw StateError('Socket closed before receiving datagram');
}

void main() {
  group('RpcTurnRelayServer', () {
    late RpcTurnRelayServer server;

    setUp(() async {
      server = RpcTurnRelayServer(
        bindAddress: InternetAddress.loopbackIPv4,
        port: 0,
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('allocates and relays UDP data', () async {
      final client = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(client.close);

      final peer = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(peer.close);

      final serverPort = server.listenPort;

      final allocationTransaction = Uint8List.fromList(List.generate(12, (i) => i));
      final allocateRequest = TurnMessage(
        method: TurnMethod.allocate,
        messageClass: TurnMessageClass.request,
        transactionId: allocationTransaction,
        attributes: [
          TurnAttribute(
            TurnAttributeType.requestedTransport,
            Uint8List.fromList(<int>[TurnRequestedTransport.udp, 0, 0, 0]),
          ),
          TurnAttribute(
            TurnAttributeType.lifetime,
            encodeLifetime(const Duration(minutes: 10)),
          ),
        ],
      );

      client.send(allocateRequest.encode(), server.bindAddress, serverPort);

      final allocationResponseDatagram = await _nextDatagram(client);
      final allocationResponse = TurnMessage.decode(allocationResponseDatagram.data);
      expect(allocationResponse, isNotNull);
      expect(allocationResponse!.messageClass, TurnMessageClass.successResponse);
      final relayedAttr = allocationResponse.firstAttribute(TurnAttributeType.xorRelayedAddress);
      expect(relayedAttr, isNotNull);
      final (relayedAddress, relayedPort) =
          decodeXorAddress(relayedAttr!, allocationResponse.transactionId);

      final permissionTransaction = Uint8List.fromList(List.generate(12, (i) => i + 10));
      final permissionRequest = TurnMessage(
        method: TurnMethod.createPermission,
        messageClass: TurnMessageClass.request,
        transactionId: permissionTransaction,
        attributes: [
          TurnAttribute(
            TurnAttributeType.xorPeerAddress,
            encodeXorAddress(peer.address, peer.port, permissionTransaction),
          ),
        ],
      );

      client.send(permissionRequest.encode(), server.bindAddress, serverPort);
      final permissionResponse =
          TurnMessage.decode((await _nextDatagram(client)).data);
      expect(permissionResponse, isNotNull);
      expect(permissionResponse!.messageClass, TurnMessageClass.successResponse);

      final payload = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final sendTransaction = Uint8List.fromList(List.generate(12, (i) => i + 20));
      final sendIndication = TurnMessage(
        method: TurnMethod.send,
        messageClass: TurnMessageClass.indication,
        transactionId: sendTransaction,
        attributes: [
          TurnAttribute(
            TurnAttributeType.xorPeerAddress,
            encodeXorAddress(peer.address, peer.port, sendTransaction),
          ),
          TurnAttribute(TurnAttributeType.data, encodeData(payload)),
        ],
      );

      client.send(sendIndication.encode(), server.bindAddress, serverPort);

      final peerDatagram = await _nextDatagram(peer);
      expect(peerDatagram.data, payload);

      final peerResponsePayload = Uint8List.fromList(List<int>.generate(16, (i) => 255 - i));
      peer.send(peerResponsePayload, relayedAddress, relayedPort);

      final clientDatagram = await _nextDatagram(client);
      final clientMessage = TurnMessage.decode(clientDatagram.data);
      expect(clientMessage, isNotNull);
      expect(clientMessage!.method, TurnMethod.data);
      expect(clientMessage.messageClass, TurnMessageClass.indication);
      final dataAttr = clientMessage.firstAttribute(TurnAttributeType.data);
      expect(dataAttr, isNotNull);
      expect(dataAttr, peerResponsePayload);
    });
  });
}
