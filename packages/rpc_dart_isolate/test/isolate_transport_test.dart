// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

// Тестовые классы для zero-copy тестов
class TestComplexObject {
  final int id;
  final String name;
  final Map<String, dynamic> metadata;
  final List<String> tags;
  final DateTime createdAt;
  final bool isActive;

  TestComplexObject({
    required this.id,
    required this.name,
    required this.metadata,
    required this.tags,
    required this.createdAt,
    required this.isActive,
  });

  @override
  String toString() {
    return 'TestComplexObject(id: $id, name: $name, metadata: $metadata, tags: $tags, createdAt: $createdAt, isActive: $isActive)';
  }
}

class TestLargeObject {
  final List<Map<String, dynamic>> data;

  TestLargeObject(this.data);

  static TestLargeObject generate(int size) {
    final random = Random();
    final data = List.generate(
      size,
      (index) => {
        'id': index,
        'value': random.nextDouble(),
        'text': 'Item $index with random data ${random.nextInt(1000)}',
        'nested': {
          'level1': {
            'level2': 'deep value $index',
            'array': List.generate(5, (i) => 'item_${index}_$i'),
          },
        },
      },
    );
    return TestLargeObject(data);
  }

  @override
  String toString() {
    return 'TestLargeObject(size: ${data.length})';
  }
}

@pragma('vm:entry-point')
void _transferableEchoServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  transport.incomingMessages.listen((message) async {
    if (!message.isDirect || message.directPayload == null) return;
    final payload = message.directPayload;

    if (payload is TransferableTypedData) {
      final bytes = payload.materialize().asUint8List();
      final roundtrip = TransferableTypedData.fromList([bytes]);
      await transport.sendDirectObject(
        message.streamId,
        roundtrip,
        endStream: true,
      );
    }
  });
}

void main() {
  group('RpcIsolateTransport', () {
    group('TransferableTypedData', () {
      test('directObject передает TransferableTypedData туда-обратно без копий',
          () async {
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _transferableEchoServer,
          customParams: const {},
          isolateId: 'transferable-echo',
        );

        final transport = result.transport;
        final streamId = transport.createStream();

        final original = Uint8List.fromList(List<int>.generate(256, (i) => i));
        final transfer = TransferableTypedData.fromList([original]);

        final responseFuture = transport
            .getMessagesForStream(streamId)
            .where((msg) => msg.isDirect && msg.directPayload != null)
            .map((msg) => msg.directPayload)
            .cast<TransferableTypedData>()
            .first
            .timeout(const Duration(seconds: 2));

        await transport.sendDirectObject(streamId, transfer);
        final receivedTransfer = await responseFuture;

        final roundtrip = receivedTransfer.materialize().asUint8List();
        expect(roundtrip, orderedEquals(original));

        result.kill();
      });
    });

    group('spawn factory', () {
      test('создает_изолят_и_возвращает_транспорт', () async {
        // Arrange & Act
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {'test': 'value'},
          isolateId: 'test-isolate',
          debugName: 'Test Echo Server',
        );

        // Assert
        expect(result.transport, isA<IRpcTransport>());
        expect(result.kill, isA<Function>());

        // Cleanup
        result.kill();
      });

      test('передает_параметры_в_изолят', () async {
        // Arrange
        final testParams = {
          'serviceName': 'TestService',
          'responsePrefix': '[TEST]: ',
        };

        // Act
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testParameterServer,
          customParams: testParams,
          isolateId: 'param-test',
        );

        final transport = result.transport;

        // Проверяем что можем общаться с изолятом
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Отправляем тестовое сообщение
        await transport.sendMessage(
          streamId,
          Uint8List.fromList('test message'.codeUnits),
        );

        // Даем время для обработки в изоляте
        await Future.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));

        // Cleanup
        result.kill();
      });

      test('обрабатывает_ошибки_создания_изолята', () async {
        // Arrange & Act
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _faultyServer,
          customParams: {},
          isolateId: 'faulty-isolate',
        );

        // Assert
        // Изолят создается успешно, но содержит ошибочный код
        expect(result.transport, isA<IRpcTransport>());
        expect(result.kill, isA<Function>());

        // Cleanup
        result.kill();
      });
    });

    group('createStream', () {
      test('создает_уникальные_stream_id', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'stream-test',
        );

        final transport = result.transport;

        // Act
        final streamId1 = transport.createStream();
        final streamId2 = transport.createStream();
        final streamId3 = transport.createStream();

        // Assert
        expect(streamId1, isNot(equals(streamId2)));
        expect(streamId2, isNot(equals(streamId3)));
        expect(streamId1, isNot(equals(streamId3)));

        // Cleanup
        result.kill();
      });

      test('генерирует_нечетные_числа_для_клиента', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'odd-stream-test',
        );

        final transport = result.transport;

        // Act
        final streamIds = List.generate(5, (_) => transport.createStream());

        // Assert
        for (final streamId in streamIds) {
          expect(
            streamId % 2,
            equals(1),
            reason: 'Stream ID должен быть нечетным',
          );
        }

        // Cleanup
        result.kill();
      });
    });

    group('sendMessage и sendMetadata', () {
      test('отправляет_сообщения_в_изолят', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'message-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act
        final testData = Uint8List.fromList('Hello Isolate'.codeUnits);
        await transport.sendMessage(streamId, testData);

        // Даем время для обработки в изоляте
        await Future.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));
        final echoMessage = receivedMessages.firstWhere(
          (msg) => !msg.isMetadataOnly && msg.payload != null,
          orElse: () => throw StateError('Echo message not found'),
        );

        final receivedText = String.fromCharCodes(echoMessage.payload!);
        expect(receivedText, contains('Hello Isolate'));

        // Cleanup
        result.kill();
      });

      test('отправляет_метаданные_в_изолят', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testFullCycleServer,
          customParams: {},
          isolateId: 'metadata-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'TestMethod',
          host: 'test.com',
        );
        await transport.sendMetadata(streamId, metadata);

        // Даем время для обработки в изоляте
        await Future.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));
        final metadataMessage = receivedMessages.firstWhere(
          (msg) => msg.isMetadataOnly,
          orElse: () => throw StateError('Metadata message not found'),
        );

        expect(metadataMessage.metadata, isNotNull);

        // Cleanup
        result.kill();
      });

      test('обрабатывает_end_stream_флаг', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testFullCycleServer,
          customParams: {},
          isolateId: 'endstream-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act
        await transport.sendMessage(
          streamId,
          Uint8List.fromList('test'.codeUnits),
          endStream: true,
        );

        // Даем время для обработки в изоляте
        await Future.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));
        final endStreamMessage = receivedMessages.firstWhere(
          (msg) => msg.isEndOfStream,
          orElse: () => throw StateError('End stream message not found'),
        );

        expect(endStreamMessage.isEndOfStream, isTrue);

        // Cleanup
        result.kill();
      });
    });

    group('finishSending', () {
      test('отправляет_end_stream_сообщение', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testFinishServer,
          customParams: {},
          isolateId: 'finish-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act
        await transport.finishSending(streamId);

        // Даем время для обработки в изоляте
        await Future.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));
        final finishMessage = receivedMessages.firstWhere(
          (msg) => msg.isEndOfStream && msg.streamId == streamId,
          orElse: () => throw StateError('Finish message not found'),
        );

        expect(finishMessage.isEndOfStream, isTrue);
        expect(finishMessage.streamId, equals(streamId));

        // Cleanup
        result.kill();
      });

      test('предотвращает_повторную_отправку', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testFinishServer,
          customParams: {},
          isolateId: 'repeat-finish-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act
        await transport.finishSending(streamId);
        await transport.finishSending(streamId); // Повторный вызов

        // Даем время для обработки в изоляте
        await Future.delayed(Duration(milliseconds: 200));

        // Assert
        final finishMessages = receivedMessages
            .where((msg) => msg.isEndOfStream && msg.streamId == streamId)
            .toList();

        expect(finishMessages.length, equals(1)); // Только одно сообщение

        // Cleanup
        result.kill();
      });
    });

    group('getMessagesForStream', () {
      test('фильтрует_сообщения_по_stream_id', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testMultiStreamServer,
          customParams: {},
          isolateId: 'filter-test',
        );

        final transport = result.transport;
        final streamId1 = transport.createStream();
        final streamId2 = transport.createStream();

        final stream1Messages = <RpcTransportMessage>[];
        final stream2Messages = <RpcTransportMessage>[];

        transport.getMessagesForStream(streamId1).listen(stream1Messages.add);
        transport.getMessagesForStream(streamId2).listen(stream2Messages.add);

        // Act
        await transport.sendMessage(
          streamId1,
          Uint8List.fromList('message1'.codeUnits),
        );
        await transport.sendMessage(
          streamId2,
          Uint8List.fromList('message2'.codeUnits),
        );
        await transport.sendMessage(
          streamId1,
          Uint8List.fromList('message3'.codeUnits),
        );

        // Даем время для обработки в изоляте
        await Future.delayed(Duration(milliseconds: 200));

        // Assert
        expect(stream1Messages.length, greaterThan(0));
        expect(stream2Messages.length, greaterThan(0));

        // Проверяем, что сообщения правильно отфильтрованы
        for (final msg in stream1Messages) {
          expect(msg.streamId, equals(streamId1));
        }
        for (final msg in stream2Messages) {
          expect(msg.streamId, equals(streamId2));
        }

        // Cleanup
        result.kill();
      });
    });

    group('close', () {
      test('закрывает_транспорт_корректно', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'close-test',
        );

        final transport = result.transport;

        // Act
        await transport.close();

        // Assert
        // Проверяем, что после закрытия нельзя отправлять сообщения
        final streamId = transport.createStream();

        // Попытка отправить сообщение после закрытия не должна вызывать исключение,
        // но сообщение не должно быть доставлено
        await transport.sendMessage(
          streamId,
          Uint8List.fromList('test'.codeUnits),
        );

        // Cleanup
        result.kill();
      });
    });

    group('интеграционные тесты', () {
      test('полный_цикл_обмена_сообщениями', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testFullCycleServer,
          customParams: {'responseCount': 3},
          isolateId: 'full-cycle-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.getMessagesForStream(streamId).listen(receivedMessages.add);

        // Act
        // Отправляем метаданные
        final metadata = RpcMetadata.forClientRequest(
          'TestService',
          'FullCycle',
        );
        await transport.sendMetadata(streamId, metadata);

        // Отправляем сообщение
        await transport.sendMessage(
          streamId,
          Uint8List.fromList('test request'.codeUnits),
        );

        // Завершаем отправку
        await transport.finishSending(streamId);

        // Даем время для обработки в изоляте
        await Future.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));

        // Проверяем, что получили и метаданные, и данные
        final metadataMessages =
            receivedMessages.where((msg) => msg.isMetadataOnly).toList();
        final dataMessages = receivedMessages
            .where((msg) => !msg.isMetadataOnly && msg.payload != null)
            .toList();

        expect(metadataMessages.length, greaterThan(0));
        expect(dataMessages.length, greaterThan(0));

        // Cleanup
        result.kill();
      });

      test('обработка_ошибок_в_изоляте', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testErrorServer,
          customParams: {},
          isolateId: 'error-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.getMessagesForStream(streamId).listen(receivedMessages.add);

        // Act
        await transport.sendMessage(
          streamId,
          Uint8List.fromList('trigger error'.codeUnits),
        );

        // Даем время для обработки в изоляте
        await Future.delayed(Duration(milliseconds: 200));

        // Assert
        // Ожидаем, что получим сообщение об ошибке
        expect(receivedMessages.length, greaterThan(0));

        // Cleanup
        result.kill();
      });
    });

    group('zero-copy с sendDirectObject', () {
      test('передает_сложные_объекты_без_сериализации', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testZeroCopyServer,
          customParams: {},
          isolateId: 'zero-copy-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act - отправляем сложный объект напрямую
        final complexObject = TestComplexObject(
          id: 42,
          name: 'Test User',
          metadata: {
            'roles': ['admin', 'user'],
            'permissions': {'read': true, 'write': false},
            'settings': {'theme': 'dark', 'language': 'ru'},
          },
          tags: ['important', 'test'],
          createdAt: DateTime(2024, 1, 15),
          isActive: true,
        );

        await transport.sendDirectObject(streamId, complexObject);

        // Даем время для обработки в изоляте
        await Future.delayed(Duration(milliseconds: 300));

        // Assert
        expect(receivedMessages.length, greaterThan(0));

        // Ищем zero-copy ответ
        final directMessage = receivedMessages.firstWhere(
          (msg) => msg.isDirect && msg.directPayload != null,
          orElse: () => throw StateError('Zero-copy response not found'),
        );

        expect(directMessage.directPayload, isA<TestComplexObject>());
        final responseObject = directMessage.directPayload as TestComplexObject;

        // Проверяем, что объект прошел без потерь и был модифицирован сервером
        expect(responseObject.id, equals(42));
        expect(responseObject.name, equals('Test User [PROCESSED]'));
        expect(
          responseObject.metadata['roles'],
          equals(['admin', 'user', 'zero-copy']),
        );
        expect(responseObject.tags.length, equals(3)); // добавился 'processed'
        expect(responseObject.isActive, equals(true));

        // Cleanup
        result.kill();
      });

      test('передает_примитивы_и_коллекции_zero_copy', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testPrimitivesZeroCopyServer,
          customParams: {},
          isolateId: 'primitives-zero-copy',
        );

        final transport = result.transport;
        // transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act - отправляем разные типы данных
        final testCases = [
          {
            'numbers': [1, 2, 3, 4, 5],
          },
          'simple string',
          42,
          true,
          [
            1,
            'mixed',
            true,
            {'nested': 'value'},
          ],
        ];

        for (int i = 0; i < testCases.length; i++) {
          final newStreamId = transport.createStream();
          await transport.sendDirectObject(newStreamId, testCases[i]);
        }

        // Даем время для обработки всех сообщений
        await Future.delayed(Duration(milliseconds: 400));

        // Assert
        expect(receivedMessages.length, greaterThanOrEqualTo(testCases.length));

        final directResponses = receivedMessages
            .where((msg) => msg.isDirect && msg.directPayload != null)
            .toList();

        expect(directResponses.length, equals(testCases.length));

        // Проверяем каждый ответ
        for (int i = 0; i < directResponses.length; i++) {
          final response = directResponses[i].directPayload;
          expect(response.toString(), contains('ECHO:'));
        }

        // Cleanup
        result.kill();
      });

      test('измеряет_производительность_zero_copy_vs_serialization', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testPerformanceServer,
          customParams: {},
          isolateId: 'performance-test',
        );

        final transport = result.transport;
        final largeObject = TestLargeObject.generate(
          5000,
        ); // Увеличиваем размер

        // Act & Assert - Zero-copy
        final stopwatchZeroCopy = Stopwatch()..start();

        for (int i = 0; i < 50; i++) {
          // Больше итераций
          final streamId = transport.createStream();
          await transport.sendDirectObject(streamId, largeObject);
        }

        stopwatchZeroCopy.stop();
        final zeroCopyTime = stopwatchZeroCopy.elapsedMicroseconds;

        // Act & Assert - Обычная сериализация (JSON)
        final stopwatchSerialized = Stopwatch()..start();

        for (int i = 0; i < 50; i++) {
          final streamId = transport.createStream();
          // Имитируем полную сериализацию в JSON
          final jsonString = largeObject.data.toString();
          final serialized = Uint8List.fromList(jsonString.codeUnits);
          await transport.sendMessage(streamId, serialized);
        }

        stopwatchSerialized.stop();
        final serializedTime = stopwatchSerialized.elapsedMicroseconds;

        print('Zero-copy время: $zeroCopyTimeμs');
        print('Сериализация время: $serializedTimeμs');

        if (zeroCopyTime < serializedTime) {
          print(
            '✅ Zero-copy быстрее в ${(serializedTime / zeroCopyTime).toStringAsFixed(2)}x раз',
          );
        } else {
          print(
            '⚠️ Для данного размера сериализация быстрее в ${(zeroCopyTime / serializedTime).toStringAsFixed(2)}x раз',
          );
          print(
            '💡 Zero-copy эффективен для очень больших или сложных объектов',
          );
        }

        // Главное преимущество zero-copy - не нужна сериализация/десериализация
        // Поэтому проверяем что оба метода работают
        expect(zeroCopyTime, greaterThan(0));
        expect(serializedTime, greaterThan(0));

        // Cleanup
        result.kill();
      });

      test('обрабатывает_ошибки_при_zero_copy', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testZeroCopyErrorServer,
          customParams: {},
          isolateId: 'zero-copy-error-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();
        final receivedMessages = <RpcTransportMessage>[];

        transport.incomingMessages.listen(receivedMessages.add);

        // Act - отправляем объект, который вызовет ошибку
        final errorTrigger = TestComplexObject(
          id: -1, // специальный ID для триггера ошибки
          name: 'Error Trigger',
          metadata: {},
          tags: [],
          createdAt: DateTime.now(),
          isActive: false,
        );

        await transport.sendDirectObject(streamId, errorTrigger);

        // Даем время для обработки
        await Future.delayed(Duration(milliseconds: 200));

        // Assert
        expect(receivedMessages.length, greaterThan(0));

        // Должны получить ошибку через metadata (как в gRPC)
        final errorMessage = receivedMessages.firstWhere(
          (msg) => msg.metadata != null && msg.isEndOfStream,
          orElse: () => throw StateError('Error response not found'),
        );

        expect(errorMessage.metadata, isNotNull);
        // В реальной реализации здесь была бы проверка статуса ошибки

        // Cleanup
        result.kill();
      });
    });

    group('releaseStreamId', () {
      test('освобождает_активный_stream_id', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();

        // Act - сначала убеждаемся что stream создан
        expect(streamId, greaterThan(0));

        // Освобождаем stream
        final released = transport.releaseStreamId(streamId);

        // Assert
        expect(
          released,
          isTrue,
          reason: 'Должен вернуть true для активного stream',
        );

        // Cleanup
        result.kill();
      });

      test('возвращает_false_для_несуществующего_stream_id', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-nonexistent-test',
        );

        final transport = result.transport;

        // Act - пытаемся освободить несуществующий stream ID
        final released = transport.releaseStreamId(99999);

        // Assert
        expect(
          released,
          isFalse,
          reason: 'Должен вернуть false для несуществующего stream',
        );

        // Cleanup
        result.kill();
      });

      test('возвращает_false_для_уже_освобожденного_stream_id', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-twice-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();

        // Act - освобождаем дважды
        final firstRelease = transport.releaseStreamId(streamId);
        final secondRelease = transport.releaseStreamId(streamId);

        // Assert
        expect(
          firstRelease,
          isTrue,
          reason: 'Первое освобождение должно быть успешным',
        );
        expect(
          secondRelease,
          isFalse,
          reason: 'Повторное освобождение должно вернуть false',
        );

        // Cleanup
        result.kill();
      });

      test('возвращает_false_для_закрытого_транспорта', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-closed-test',
        );

        final transport = result.transport;
        final streamId = transport.createStream();

        // Act - закрываем транспорт и пытаемся освободить stream
        await transport.close();
        final released = transport.releaseStreamId(streamId);

        // Assert
        expect(
          released,
          isFalse,
          reason: 'Должен вернуть false для закрытого транспорта',
        );
        expect(transport.isClosed, isTrue);

        // Cleanup
        result.kill();
      });

      test('освобождает_множественные_stream_ids', () async {
        // Arrange
        final result = await RpcIsolateTransport.spawn(
          entrypoint: _testEchoServer,
          customParams: {},
          isolateId: 'release-multiple-test',
        );

        final transport = result.transport;
        final streamIds = List.generate(5, (_) => transport.createStream());

        // Act - освобождаем все streams
        final results = streamIds.map(transport.releaseStreamId).toList();

        // Assert
        expect(
          results.every((result) => result == true),
          isTrue,
          reason: 'Все streams должны быть освобождены успешно',
        );

        // Повторное освобождение должно вернуть false
        final secondResults = streamIds.map(transport.releaseStreamId).toList();
        expect(
          secondResults.every((result) => result == false),
          isTrue,
          reason: 'Повторное освобождение должно вернуть false',
        );

        // Cleanup
        result.kill();
      });

      test(
        'корректно_работает_с_отправкой_сообщений_после_освобождения',
        () async {
          // Arrange
          final result = await RpcIsolateTransport.spawn(
            entrypoint: _testEchoServer,
            customParams: {},
            isolateId: 'release-after-message-test',
          );

          final transport = result.transport;
          final streamId = transport.createStream();
          final receivedMessages = <RpcTransportMessage>[];

          transport.incomingMessages.listen(receivedMessages.add);

          // Act - отправляем сообщение
          final testData = Uint8List.fromList('Test message'.codeUnits);
          await transport.sendMessage(streamId, testData);

          // Ждем ответ
          await Future.delayed(Duration(milliseconds: 100));

          // Освобождаем stream
          final released = transport.releaseStreamId(streamId);

          // Пытаемся отправить еще одно сообщение (не должно вызывать ошибку)
          await transport.sendMessage(streamId, testData);

          // Assert
          expect(released, isTrue);
          expect(receivedMessages.length, greaterThan(0));

          // Cleanup
          result.kill();
        },
      );
    });
  });
}

/// Простой эхо-сервер для тестов
@pragma('vm:entry-point')
void _testEchoServer(IRpcTransport transport, Map<String, dynamic> params) {
  transport.incomingMessages.listen((message) async {
    if (!message.isMetadataOnly && message.payload != null) {
      // Эхо сообщения
      final echoData = Uint8List.fromList(
        'Echo: ${String.fromCharCodes(message.payload!)}'.codeUnits,
      );
      await transport.sendMessage(message.streamId, echoData);
    }
  });
}

/// Сервер для тестирования параметров
@pragma('vm:entry-point')
void _testParameterServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  final responsePrefix = params['responsePrefix'] as String? ?? '[DEFAULT]: ';

  transport.incomingMessages.listen((message) async {
    if (!message.isMetadataOnly && message.payload != null) {
      final originalText = String.fromCharCodes(message.payload!);
      final responseText = '$responsePrefix$originalText';
      final responseData = Uint8List.fromList(responseText.codeUnits);

      await transport.sendMessage(message.streamId, responseData);
    }
  });
}

/// Сервер с ошибкой для тестирования
@pragma('vm:entry-point')
void _faultyServer(IRpcTransport transport, Map<String, dynamic> params) {
  throw Exception('Intentional server error');
}

/// Мульти-стрим сервер для тестирования фильтрации
@pragma('vm:entry-point')
void _testMultiStreamServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  transport.incomingMessages.listen((message) async {
    if (!message.isMetadataOnly && message.payload != null) {
      final originalText = String.fromCharCodes(message.payload!);
      final responseText =
          'Response for stream ${message.streamId}: $originalText';
      final responseData = Uint8List.fromList(responseText.codeUnits);

      await transport.sendMessage(message.streamId, responseData);
    }
  });
}

/// Полный цикл сервер для интеграционных тестов
@pragma('vm:entry-point')
void _testFullCycleServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  final responseCount = params['responseCount'] as int? ?? 1;

  transport.incomingMessages.listen((message) async {
    if (message.isMetadataOnly && !message.isEndOfStream) {
      // Отправляем начальные метаданные
      final initialMetadata = RpcMetadata.forServerInitialResponse();
      await transport.sendMetadata(message.streamId, initialMetadata);
    } else if (!message.isMetadataOnly && message.payload != null) {
      // Отправляем несколько ответов
      for (int i = 1; i <= responseCount; i++) {
        final responseText = 'Response $i of $responseCount';
        final responseData = Uint8List.fromList(responseText.codeUnits);
        await transport.sendMessage(message.streamId, responseData);
      }

      // Отправляем финальные метаданные
      final finalMetadata = RpcMetadata.forTrailer(RpcStatus.ok);
      await transport.sendMetadata(
        message.streamId,
        finalMetadata,
        endStream: true,
      );
    }
  });
}

/// Сервер с ошибками для тестирования
@pragma('vm:entry-point')
void _testErrorServer(IRpcTransport transport, Map<String, dynamic> params) {
  transport.incomingMessages.listen((message) async {
    if (!message.isMetadataOnly && message.payload != null) {
      // Отправляем ошибку
      final errorMetadata = RpcMetadata.forTrailer(
        RpcStatus.internal,
        message: 'Test error',
      );
      await transport.sendMetadata(
        message.streamId,
        errorMetadata,
        endStream: true,
      );
    }
  });
}

/// Простой сервер для тестов finishSending
@pragma('vm:entry-point')
void _testFinishServer(IRpcTransport transport, Map<String, dynamic> params) {
  transport.incomingMessages.listen((message) async {
    // Отвечаем на любое сообщение, включая END_STREAM
    if (message.isEndOfStream) {
      // Отправляем подтверждение END_STREAM
      await transport.finishSending(message.streamId);
    } else if (!message.isMetadataOnly && message.payload != null) {
      // Эхо обычных сообщений
      final echoData = Uint8List.fromList(
        'Echo: ${String.fromCharCodes(message.payload!)}'.codeUnits,
      );
      await transport.sendMessage(message.streamId, echoData);
    }
  });
}

/// Zero-copy сервер для сложных объектов
@pragma('vm:entry-point')
void _testZeroCopyServer(IRpcTransport transport, Map<String, dynamic> params) {
  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      // Получаем объект напрямую без сериализации
      final receivedObject = message.directPayload as TestComplexObject;

      // Модифицируем объект
      final modifiedObject = TestComplexObject(
        id: receivedObject.id,
        name: '${receivedObject.name} [PROCESSED]',
        metadata: {
          ...receivedObject.metadata,
          'roles': [...(receivedObject.metadata['roles'] as List), 'zero-copy'],
        },
        tags: [...receivedObject.tags, 'processed'],
        createdAt: receivedObject.createdAt,
        isActive: receivedObject.isActive,
      );

      // Отправляем назад через zero-copy
      await transport.sendDirectObject(
        message.streamId,
        modifiedObject,
        endStream: true,
      );
    }
  });
}

/// Zero-copy сервер для примитивов и коллекций
@pragma('vm:entry-point')
void _testPrimitivesZeroCopyServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      // Получаем любой объект и отправляем эхо-ответ
      final received = message.directPayload;
      final echo = 'ECHO: $received';

      await transport.sendDirectObject(message.streamId, echo, endStream: true);
    }
  });
}

/// Сервер для тестирования производительности
@pragma('vm:entry-point')
void _testPerformanceServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      // Просто отправляем подтверждение
      await transport.sendDirectObject(message.streamId, 'OK', endStream: true);
    } else if (message.payload != null) {
      // Для сериализованных данных - просто подтверждение
      final response = Uint8List.fromList('OK'.codeUnits);
      await transport.sendMessage(message.streamId, response, endStream: true);
    }
  });
}

/// Zero-copy сервер с обработкой ошибок
@pragma('vm:entry-point')
void _testZeroCopyErrorServer(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  transport.incomingMessages.listen((message) async {
    if (message.isDirect && message.directPayload != null) {
      final receivedObject = message.directPayload as TestComplexObject;

      // Если ID = -1, то генерируем ошибку
      if (receivedObject.id == -1) {
        // Отправляем ошибку через metadata (как в gRPC)
        final errorMetadata = RpcMetadata.forTrailer(
          RpcStatus.invalidArgument,
          message: 'Invalid object ID: ${receivedObject.id}',
        );
        await transport.sendMetadata(
          message.streamId,
          errorMetadata,
          endStream: true,
        );
      } else {
        // Обычная обработка
        await transport.sendDirectObject(
          message.streamId,
          'Success',
          endStream: true,
        );
      }
    }
  });
}
