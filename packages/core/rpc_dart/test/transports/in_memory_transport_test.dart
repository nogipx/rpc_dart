// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/src/rpc/_index.dart';
import 'package:test/test.dart';

void main() {
  group('RpcInMemoryTransport', () {
    group('pair factory', () {
      test('creates two connected transports', () {
        final (transport1, transport2) = RpcInMemoryTransport.pair();

        expect(transport1, isA<IRpcTransport>());
        expect(transport2, isA<IRpcTransport>());
        expect(transport1, isNot(same(transport2)));
      });

      test('transports are linked', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        final streamId = transport1.createStream();
        final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
        await transport1.sendMessage(streamId, testData);

        await Future.delayed(Duration(milliseconds: 1));

        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.streamId, equals(streamId));
        expect(receivedMessages.first.payload, equals(testData));
      });

      test('supports zero copy', () {
        final (transport1, transport2) = RpcInMemoryTransport.pair();

        expect(transport1.supportsZeroCopy, isTrue);
        expect(transport2.supportsZeroCopy, isTrue);
      });
    });

    group('createStream', () {
      test('creates unique stream IDs', () {
        final (transport, _) = RpcInMemoryTransport.pair();

        final streamId1 = transport.createStream();
        final streamId2 = transport.createStream();
        final streamId3 = transport.createStream();

        expect(streamId1, isNot(equals(streamId2)));
        expect(streamId2, isNot(equals(streamId3)));
        expect(streamId1, isNot(equals(streamId3)));
      });

      test('generates odd IDs for client', () {
        final (clientTransport, _) = RpcInMemoryTransport.pair();

        final streamIds = List.generate(
          5,
          (_) => clientTransport.createStream(),
        );

        for (final streamId in streamIds) {
          expect(streamId % 2, equals(1));
        }
      });

      test('generates even IDs for server', () {
        final (_, serverTransport) = RpcInMemoryTransport.pair();

        final streamIds = List.generate(
          5,
          (_) => serverTransport.createStream(),
        );

        for (final streamId in streamIds) {
          expect(streamId % 2, equals(0));
        }
      });
    });

    group('sendMessage and sendMetadata', () {
      test('sends messages between transports', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        final streamId = transport1.createStream();
        final testData = Uint8List.fromList('Hello World'.codeUnits);
        await transport1.sendMessage(streamId, testData);

        await Future.delayed(Duration(milliseconds: 1));

        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.streamId, equals(streamId));
        expect(receivedMessages.first.payload, equals(testData));
        expect(receivedMessages.first.isMetadataOnly, isFalse);
      });

      test('sends metadata between transports', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        final streamId = transport1.createStream();
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
        );
        await transport1.sendMetadata(streamId, metadata);

        await Future.delayed(Duration(milliseconds: 1));

        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.streamId, equals(streamId));
        expect(receivedMessages.first.metadata, equals(metadata));
        expect(receivedMessages.first.isMetadataOnly, isTrue);
      });

      test('handles end stream flag', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        final streamId = transport1.createStream();
        await transport1.sendMessage(
          streamId,
          Uint8List.fromList('test'.codeUnits),
          endStream: true,
        );

        await Future.delayed(Duration(milliseconds: 1));

        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.isEndOfStream, isTrue);
      });

      test('bidirectional messaging', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final messages1 = <RpcTransportMessage>[];
        final messages2 = <RpcTransportMessage>[];

        transport1.incomingMessages.listen(messages1.add);
        transport2.incomingMessages.listen(messages2.add);

        final streamId1 = transport1.createStream();
        final streamId2 = transport2.createStream();

        await transport1.sendMessage(
          streamId1,
          Uint8List.fromList('from1'.codeUnits),
        );
        await transport2.sendMessage(
          streamId2,
          Uint8List.fromList('from2'.codeUnits),
        );

        await Future.delayed(Duration(milliseconds: 1));

        expect(messages1.length, equals(1));
        expect(messages2.length, equals(1));
        expect(String.fromCharCodes(messages2.first.payload!), equals('from1'));
        expect(String.fromCharCodes(messages1.first.payload!), equals('from2'));
      });
    });

    group('sendDirectObject', () {
      test('sends objects by reference (zero-copy)', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        final streamId = transport1.createStream();
        final testObject = {'key': 'value', 'number': 42};
        await transport1.sendDirectObject(streamId, testObject);

        await Future.delayed(Duration(milliseconds: 1));

        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.directPayload, same(testObject));
      });
    });

    group('finishSending', () {
      test('sends end stream message', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        final streamId = transport1.createStream();
        await transport1.finishSending(streamId);

        await Future.delayed(Duration(milliseconds: 1));

        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.streamId, equals(streamId));
        expect(receivedMessages.first.isEndOfStream, isTrue);
        expect(receivedMessages.first.isMetadataOnly, isTrue);
      });

      test('prevents duplicate send', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        final streamId = transport1.createStream();
        await transport1.finishSending(streamId);
        await transport1.finishSending(streamId);

        await Future.delayed(Duration(milliseconds: 1));

        final endStreamMessages = receivedMessages
            .where((msg) => msg.isEndOfStream && msg.streamId == streamId)
            .toList();
        expect(endStreamMessages.length, equals(1));
      });
    });

    group('getMessagesForStream', () {
      test('filters messages by stream ID', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final streamId1 = transport1.createStream();
        final streamId2 = transport1.createStream();

        final stream1Messages = <RpcTransportMessage>[];
        final stream2Messages = <RpcTransportMessage>[];

        transport2.getMessagesForStream(streamId1).listen(stream1Messages.add);
        transport2.getMessagesForStream(streamId2).listen(stream2Messages.add);

        await transport1.sendMessage(
          streamId1,
          Uint8List.fromList('message1'.codeUnits),
        );
        await transport1.sendMessage(
          streamId2,
          Uint8List.fromList('message2'.codeUnits),
        );
        await transport1.sendMessage(
          streamId1,
          Uint8List.fromList('message3'.codeUnits),
        );

        await Future.delayed(Duration(milliseconds: 1));

        expect(stream1Messages.length, equals(2));
        expect(stream2Messages.length, equals(1));
        expect(
          String.fromCharCodes(stream1Messages[0].payload!),
          equals('message1'),
        );
        expect(
          String.fromCharCodes(stream2Messages[0].payload!),
          equals('message2'),
        );
        expect(
          String.fromCharCodes(stream1Messages[1].payload!),
          equals('message3'),
        );
      });

      test('does not receive messages from other streams', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final streamId1 = transport1.createStream();
        final streamId2 = transport1.createStream();

        final stream1Messages = <RpcTransportMessage>[];
        transport2.getMessagesForStream(streamId1).listen(stream1Messages.add);

        await transport1.sendMessage(
          streamId2,
          Uint8List.fromList('message'.codeUnits),
        );

        expect(stream1Messages, isEmpty);
      });
    });

    group('close', () {
      test('closes transport cleanly', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();

        await transport1.close();
        await transport2.close();
      });

      test('stops receiving messages after close', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        await transport2.close();

        final streamId = transport1.createStream();
        await transport1.sendMessage(
          streamId,
          Uint8List.fromList('test'.codeUnits),
        );

        expect(receivedMessages, isEmpty);
      });
    });

    group('integration tests', () {
      test('full message exchange cycle', () async {
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        final serverMessages = <RpcTransportMessage>[];
        final clientMessages = <RpcTransportMessage>[];

        serverTransport.incomingMessages.listen(serverMessages.add);
        clientTransport.incomingMessages.listen(clientMessages.add);

        // Client sends request
        final requestStreamId = clientTransport.createStream();
        final requestMetadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
        );
        await clientTransport.sendMetadata(requestStreamId, requestMetadata);
        await clientTransport.sendMessage(
          requestStreamId,
          Uint8List.fromList('test request'.codeUnits),
        );
        await clientTransport.finishSending(requestStreamId);

        // Server sends response
        final responseStreamId = serverTransport.createStream();
        final responseMetadata = RpcMetadata.forServerInitialResponse();
        await serverTransport.sendMetadata(responseStreamId, responseMetadata);
        await serverTransport.sendMessage(
          responseStreamId,
          Uint8List.fromList('test response'.codeUnits),
        );
        final trailerMetadata = RpcMetadata.forTrailer(RpcStatus.ok);
        await serverTransport.sendMetadata(
          responseStreamId,
          trailerMetadata,
          endStream: true,
        );

        await Future.delayed(Duration(milliseconds: 1));

        // Verify request
        expect(serverMessages.length, equals(3));
        expect(serverMessages[0].isMetadataOnly, isTrue);
        expect(serverMessages[0].metadata?.serviceName, equals('TestService'));
        expect(serverMessages[1].isMetadataOnly, isFalse);
        expect(
          String.fromCharCodes(serverMessages[1].payload!),
          equals('test request'),
        );
        expect(serverMessages[2].isEndOfStream, isTrue);

        // Verify response
        expect(clientMessages.length, equals(3));
        expect(clientMessages[0].isMetadataOnly, isTrue);
        expect(clientMessages[1].isMetadataOnly, isFalse);
        expect(
          String.fromCharCodes(clientMessages[1].payload!),
          equals('test response'),
        );
        expect(clientMessages[2].isEndOfStream, isTrue);
      });

      test('multiple streams on one transport', () async {
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        final streamIds = [
          transport1.createStream(),
          transport1.createStream(),
          transport1.createStream(),
        ];

        for (int i = 0; i < streamIds.length; i++) {
          await transport1.sendMessage(
            streamIds[i],
            Uint8List.fromList('message_$i'.codeUnits),
          );
        }

        await Future.delayed(Duration(milliseconds: 1));

        expect(receivedMessages.length, equals(3));

        for (int i = 0; i < streamIds.length; i++) {
          final message = receivedMessages[i];
          expect(message.streamId, equals(streamIds[i]));
          expect(String.fromCharCodes(message.payload!), equals('message_$i'));
        }
      });
    });
  });

  group('Partner auto-close', () {
    test('closing client transport closes server', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      expect(clientTransport.isClosed, isFalse);
      expect(serverTransport.isClosed, isFalse);

      await clientTransport.close();
      await Future.delayed(Duration(milliseconds: 10));

      expect(clientTransport.isClosed, isTrue);
      expect(serverTransport.isClosed, isTrue);
    });

    test('closing server transport closes client', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      expect(clientTransport.isClosed, isFalse);
      expect(serverTransport.isClosed, isFalse);

      await serverTransport.close();
      await Future.delayed(Duration(milliseconds: 10));

      expect(clientTransport.isClosed, isTrue);
      expect(serverTransport.isClosed, isTrue);
    });

    test('double close does not throw', () async {
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      await Future.wait([clientTransport.close(), serverTransport.close()]);

      expect(clientTransport.isClosed, isTrue);
      expect(serverTransport.isClosed, isTrue);

      await clientTransport.close();
      await serverTransport.close();
    });

    group('health & reconnect', () {
      test('returns healthy when active', () async {
        final (clientTransport, _) = RpcInMemoryTransport.pair();

        final status = await clientTransport.health();

        expect(status.level, equals(RpcHealthLevel.healthy));
      });

      test('returns closed after close', () async {
        final (clientTransport, _) = RpcInMemoryTransport.pair();

        await clientTransport.close();

        final status = await clientTransport.health();

        expect(status.level, equals(RpcHealthLevel.closed));
      });

      test('reconnect returns degraded', () async {
        final (clientTransport, _) = RpcInMemoryTransport.pair();

        final status = await clientTransport.reconnect();

        expect(status.level, equals(RpcHealthLevel.degraded));
        expect(status.details['supported'], isFalse);
      });
    });
  });
}
