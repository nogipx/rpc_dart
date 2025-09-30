// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha1;
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

  group('TurnRelayServer with authentication', () {
    const username = 'alice';
    const password = 'p@ssw0rd';
    const realm = 'example.org';
    const nonce = 'nonce-token';

    late TurnRelayServer server;
    late StaticTurnCredentialStore credentialStore;
    late TurnCredential credential;

    setUp(() async {
      credentialStore = StaticTurnCredentialStore(
        realm: realm,
        nonce: nonce,
        credentials: {
          username: TurnCredential(
            username: username,
            password: password,
            type: TurnCredentialType.longTerm,
          ),
        },
      );
      credential = credentialStore.lookup(username)!;

      server = TurnRelayServer(
        bindAddress: InternetAddress.loopbackIPv4,
        bindPort: 0,
        credentialStore: credentialStore,
      );
      await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('rejects unauthenticated allocate request', () async {
      final socket = await Socket.connect(server.bindAddress, server.port);
      final turnMessages = StreamController<TurnMessage>.broadcast();
      final frameDecoder = TurnTcpFrameDecoder(
        onTurnMessage: turnMessages.add,
        onChannelData: (_, __) {},
      );

      final socketSub = socket.listen((Uint8List data) {
        if (data.isNotEmpty) {
          frameDecoder.addChunk(data);
        }
      });

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
            Uint8List.fromList(<int>[TurnRequestedTransport.tcp, 0, 0, 0]),
          ),
        ],
      );

      socket.add(allocateRequest.encode());

      final response = await turnMessages.stream.first.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw StateError('allocate response timeout'),
      );

      expect(response.messageClass, TurnMessageClass.errorResponse);
      final errorAttr = response.firstAttribute(TurnAttributeType.errorCode);
      expect(errorAttr, isNotNull);
      expect(_decodeErrorCode(errorAttr!), 401);
      expect(server.allocations, isEmpty);
    });

    test('accepts authenticated allocate request', () async {
      final socket = await Socket.connect(server.bindAddress, server.port);
      final turnMessages = StreamController<TurnMessage>.broadcast();
      final frameDecoder = TurnTcpFrameDecoder(
        onTurnMessage: turnMessages.add,
        onChannelData: (_, __) {},
      );

      final socketSub = socket.listen((Uint8List data) {
        if (data.isNotEmpty) {
          frameDecoder.addChunk(data);
        }
      });

      addTearDown(() async {
        await socketSub.cancel();
        await turnMessages.close();
        await socket.close();
      });

      final request = _buildAuthenticatedRequest(
        method: TurnMethod.allocate,
        additional: [
          TurnAttribute(
            TurnAttributeType.requestedTransport,
            Uint8List.fromList(<int>[TurnRequestedTransport.tcp, 0, 0, 0]),
          ),
        ],
        credential: credential,
        store: credentialStore,
      );

      socket.add(request.encode());

      final response = await turnMessages.stream.first.timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw StateError('allocate response timeout'),
      );

      expect(response.messageClass, TurnMessageClass.successResponse);
      expect(server.allocations, isNotEmpty);
    });
  });
}

int _decodeErrorCode(Uint8List errorAttribute) {
  final data = ByteData.sublistView(errorAttribute);
  final classValue = data.getUint8(2);
  final number = data.getUint8(3);
  return classValue * 100 + number;
}

TurnMessage _buildAuthenticatedRequest({
  required int method,
  required List<TurnAttribute> additional,
  required TurnCredential credential,
  required TurnCredentialStore store,
}) {
  final transactionId = TurnMessage.generateTransactionId();
  final attributes = <TurnAttribute>[
    TurnAttribute(
      TurnAttributeType.username,
      Uint8List.fromList(utf8.encode(credential.username)),
    ),
    TurnAttribute(
      TurnAttributeType.realm,
      Uint8List.fromList(utf8.encode(store.realm)),
    ),
    TurnAttribute(
      TurnAttributeType.nonce,
      Uint8List.fromList(utf8.encode(store.nonce)),
    ),
    ...additional,
  ];

  final placeholder = TurnAttribute(
    TurnAttributeType.messageIntegrity,
    Uint8List(20),
  );
  final unsigned = TurnMessage(
    method: method,
    messageClass: TurnMessageClass.request,
    transactionId: transactionId,
    attributes: [...attributes, placeholder],
  );

  final key = credential.deriveKey(store.realm);
  return _signMessage(unsigned, key);
}

TurnMessage _signMessage(TurnMessage message, Uint8List key) {
  final encoded = message.encode();
  var offset = 20;
  late int integrityIndex;
  for (var i = 0; i < message.attributes.length; i++) {
    final attribute = message.attributes[i];
    final length = attribute.value.length;
    final paddedLength = (length + 3) & ~3;
    if (attribute.type == TurnAttributeType.messageIntegrity) {
      integrityIndex = i;
      break;
    }
    offset += 4 + paddedLength;
  }

  final hmac = Hmac(sha1, key).convert(encoded.sublist(0, offset));
  final attributes = [...message.attributes];
  attributes[integrityIndex] = TurnAttribute(
    TurnAttributeType.messageIntegrity,
    Uint8List.fromList(hmac.bytes),
  );

  return TurnMessage(
    method: message.method,
    messageClass: message.messageClass,
    transactionId: message.transactionId,
    attributes: attributes,
  );
}
