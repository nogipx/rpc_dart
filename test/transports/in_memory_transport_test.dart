import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:rpc_dart/src/rpc/_index.dart';

void main() {
  group('RpcInMemoryTransport', () {
    group('pair factory', () {
      test('создает_два_соединенных_транспорта', () {
        // Arrange & Act
        final (transport1, transport2) = RpcInMemoryTransport.pair();

        // Assert
        expect(transport1, isA<RpcInMemoryTransport>());
        expect(transport2, isA<RpcInMemoryTransport>());
        expect(transport1, isNot(same(transport2)));
      });

      test('транспорты_связаны_друг_с_другом', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        // Act
        final streamId = transport1.createStream();
        final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
        await transport1.sendMessage(streamId, testData);

        // Give time for async processing
        await Future.delayed(Duration(milliseconds: 10));

        // Assert
        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.streamId, equals(streamId));
        expect(receivedMessages.first.payload, equals(testData));
      });
    });

    group('createStream', () {
      test('создает_уникальные_stream_id', () {
        // Arrange
        final (transport, _) = RpcInMemoryTransport.pair();

        // Act
        final streamId1 = transport.createStream();
        final streamId2 = transport.createStream();
        final streamId3 = transport.createStream();

        // Assert
        expect(streamId1, isNot(equals(streamId2)));
        expect(streamId2, isNot(equals(streamId3)));
        expect(streamId1, isNot(equals(streamId3)));
      });

      test('генерирует_нечетные_числа_для_клиента', () {
        // Arrange
        final (clientTransport, _) = RpcInMemoryTransport.pair();

        // Act
        final streamIds =
            List.generate(5, (_) => clientTransport.createStream());

        // Assert
        for (final streamId in streamIds) {
          expect(streamId % 2, equals(1),
              reason: 'Stream ID должен быть нечетным для клиента');
        }
      });

      test('генерирует_четные_числа_для_сервера', () {
        // Arrange
        final (_, serverTransport) = RpcInMemoryTransport.pair();

        // Act
        final streamIds =
            List.generate(5, (_) => serverTransport.createStream());

        // Assert
        for (final streamId in streamIds) {
          expect(streamId % 2, equals(0),
              reason: 'Stream ID должен быть четным для сервера');
        }
      });
    });

    group('sendMessage и sendMetadata', () {
      test('отправляет_сообщения_между_транспортами', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        // Act
        final streamId = transport1.createStream();
        final testData = Uint8List.fromList('Hello World'.codeUnits);
        await transport1.sendMessage(streamId, testData);

        // Give time for async processing
        await Future.delayed(Duration(milliseconds: 10));

        // Assert
        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.streamId, equals(streamId));
        expect(receivedMessages.first.payload, equals(testData));
        expect(receivedMessages.first.isMetadataOnly, isFalse);
      });

      test('отправляет_метаданные_между_транспортами', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        // Act
        final streamId = transport1.createStream();
        final metadata =
            RpcMetadata.forClientRequest('TestService', 'TestMethod');
        await transport1.sendMetadata(streamId, metadata);

        // Give time for async processing
        await Future.delayed(Duration(milliseconds: 10));

        // Assert
        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.streamId, equals(streamId));
        expect(receivedMessages.first.metadata, equals(metadata));
        expect(receivedMessages.first.isMetadataOnly, isTrue);
      });

      test('обрабатывает_end_stream_флаг', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        // Act
        final streamId = transport1.createStream();
        await transport1.sendMessage(
          streamId,
          Uint8List.fromList('test'.codeUnits),
          endStream: true,
        );

        // Give time for async processing
        await Future.delayed(Duration(milliseconds: 10));

        // Assert
        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.isEndOfStream, isTrue);
      });

      test('двунаправленная_передача_сообщений', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final messages1 = <RpcTransportMessage>[];
        final messages2 = <RpcTransportMessage>[];

        transport1.incomingMessages.listen(messages1.add);
        transport2.incomingMessages.listen(messages2.add);

        // Act
        final streamId1 = transport1.createStream();
        final streamId2 = transport2.createStream();

        await transport1.sendMessage(
            streamId1, Uint8List.fromList('from1'.codeUnits));
        await transport2.sendMessage(
            streamId2, Uint8List.fromList('from2'.codeUnits));

        // Give time for async processing
        await Future.delayed(Duration(milliseconds: 10));

        // Assert
        expect(messages1.length, equals(1));
        expect(messages2.length, equals(1));
        expect(String.fromCharCodes(messages2.first.payload!), equals('from1'));
        expect(String.fromCharCodes(messages1.first.payload!), equals('from2'));
      });
    });

    group('finishSending', () {
      test('отправляет_end_stream_сообщение', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        // Act
        final streamId = transport1.createStream();
        await transport1.finishSending(streamId);

        // Give time for async processing
        await Future.delayed(Duration(milliseconds: 10));

        // Assert
        expect(receivedMessages.length, equals(1));
        expect(receivedMessages.first.streamId, equals(streamId));
        expect(receivedMessages.first.isEndOfStream, isTrue);
        expect(receivedMessages.first.isMetadataOnly, isTrue);
      });

      test('предотвращает_повторную_отправку', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        // Act
        final streamId = transport1.createStream();
        await transport1.finishSending(streamId);
        await transport1.finishSending(streamId); // Повторный вызов

        // Assert
        final endStreamMessages = receivedMessages
            .where((msg) => msg.isEndOfStream && msg.streamId == streamId)
            .toList();
        expect(endStreamMessages.length, equals(1));
      });
    });

    group('getMessagesForStream', () {
      test('фильтрует_сообщения_по_stream_id', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final streamId1 = transport1.createStream();
        final streamId2 = transport1.createStream();

        final stream1Messages = <RpcTransportMessage>[];
        final stream2Messages = <RpcTransportMessage>[];

        transport2.getMessagesForStream(streamId1).listen(stream1Messages.add);
        transport2.getMessagesForStream(streamId2).listen(stream2Messages.add);

        // Act
        await transport1.sendMessage(
            streamId1, Uint8List.fromList('message1'.codeUnits));
        await transport1.sendMessage(
            streamId2, Uint8List.fromList('message2'.codeUnits));
        await transport1.sendMessage(
            streamId1, Uint8List.fromList('message3'.codeUnits));

        // Give time for async processing
        await Future.delayed(Duration(milliseconds: 10));

        // Assert
        expect(stream1Messages.length, equals(2));
        expect(stream2Messages.length, equals(1));
        expect(String.fromCharCodes(stream1Messages[0].payload!),
            equals('message1'));
        expect(String.fromCharCodes(stream2Messages[0].payload!),
            equals('message2'));
        expect(String.fromCharCodes(stream1Messages[1].payload!),
            equals('message3'));
      });

      test('не_получает_сообщения_от_других_потоков', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final streamId1 = transport1.createStream();
        final streamId2 = transport1.createStream();

        final stream1Messages = <RpcTransportMessage>[];
        transport2.getMessagesForStream(streamId1).listen(stream1Messages.add);

        // Act
        await transport1.sendMessage(
            streamId2, Uint8List.fromList('message'.codeUnits));

        // Assert
        expect(stream1Messages, isEmpty);
      });
    });

    group('close', () {
      test('закрывает_транспорт_корректно', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();

        // Act & Assert - должно закрыться без ошибок
        await transport1.close();
        await transport2.close();
      });

      test('прекращает_прием_сообщений_после_закрытия', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        // Act
        await transport2.close();

        final streamId = transport1.createStream();
        await transport1.sendMessage(
            streamId, Uint8List.fromList('test'.codeUnits));

        // Assert
        expect(receivedMessages, isEmpty);
      });
    });

    group('интеграционные тесты', () {
      test('полный_цикл_обмена_сообщениями', () async {
        // Arrange
        final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
        final serverMessages = <RpcTransportMessage>[];
        final clientMessages = <RpcTransportMessage>[];

        serverTransport.incomingMessages.listen(serverMessages.add);
        clientTransport.incomingMessages.listen(clientMessages.add);

        // Act
        // Клиент отправляет запрос
        final requestStreamId = clientTransport.createStream();
        final requestMetadata =
            RpcMetadata.forClientRequest('TestService', 'TestMethod');
        await clientTransport.sendMetadata(requestStreamId, requestMetadata);
        await clientTransport.sendMessage(
          requestStreamId,
          Uint8List.fromList('test request'.codeUnits),
        );
        await clientTransport.finishSending(requestStreamId);

        // Сервер отправляет ответ
        final responseStreamId = serverTransport.createStream();
        final responseMetadata = RpcMetadata.forServerInitialResponse();
        await serverTransport.sendMetadata(responseStreamId, responseMetadata);
        await serverTransport.sendMessage(
          responseStreamId,
          Uint8List.fromList('test response'.codeUnits),
        );
        final trailerMetadata = RpcMetadata.forTrailer(RpcStatus.OK);
        await serverTransport.sendMetadata(responseStreamId, trailerMetadata,
            endStream: true);

        // Give time for async processing
        await Future.delayed(Duration(milliseconds: 10));

        // Assert
        expect(
            serverMessages.length, equals(3)); // metadata + message + endStream
        expect(
            clientMessages.length, equals(3)); // metadata + message + trailer

        // Проверяем запрос
        expect(serverMessages[0].isMetadataOnly, isTrue);
        expect(serverMessages[0].metadata?.serviceName, equals('TestService'));
        expect(serverMessages[1].isMetadataOnly, isFalse);
        expect(String.fromCharCodes(serverMessages[1].payload!),
            equals('test request'));
        expect(serverMessages[2].isEndOfStream, isTrue);

        // Проверяем ответ
        expect(clientMessages[0].isMetadataOnly, isTrue);
        expect(clientMessages[1].isMetadataOnly, isFalse);
        expect(String.fromCharCodes(clientMessages[1].payload!),
            equals('test response'));
        expect(clientMessages[2].isEndOfStream, isTrue);
      });

      test('множественные_потоки_на_одном_транспорте', () async {
        // Arrange
        final (transport1, transport2) = RpcInMemoryTransport.pair();
        final receivedMessages = <RpcTransportMessage>[];

        transport2.incomingMessages.listen(receivedMessages.add);

        // Act
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

        // Give time for async processing
        await Future.delayed(Duration(milliseconds: 10));

        // Assert
        expect(receivedMessages.length, equals(3));

        // Проверяем, что все сообщения получены с правильными stream ID
        for (int i = 0; i < streamIds.length; i++) {
          final message = receivedMessages[i];
          expect(message.streamId, equals(streamIds[i]));
          expect(String.fromCharCodes(message.payload!), equals('message_$i'));
        }
      });
    });
  });
}
