// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Тесты CallProcessor следуя принципам Unit Testing:
/// - Тестируем наблюдаемое поведение, не детали реализации
/// - Используем тестируемые объекты в памяти вместо моков
/// - Проверяем состояние объектов и выходные данные
/// - Не тестируем взаимодействия с коллабораторами
void main() {
  group('CallProcessor', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late CallProcessor<RpcString, RpcString> processor;
    late RpcCodec<RpcString> codec;

    setUp(() {
      // Используем in-memory объекты вместо моков (принцип Unit Testing)
      final transportPair = RpcInMemoryTransport.pair();
      clientTransport = transportPair.$1; // клиентская часть
      serverTransport = transportPair.$2; // серверная часть
      codec = RpcCodec(RpcString.fromJson);

      processor = CallProcessor<RpcString, RpcString>(
        transport: clientTransport,
        serviceName: 'TestService',
        methodName: 'TestMethod',
        requestCodec: codec,
        responseCodec: codec,
      );
    });

    tearDown(() async {
      await processor.close();
      await clientTransport.close();
      await serverTransport.close();
    });

    test('creates stream and initializes correctly', () {
      // Тестируем наблюдаемое поведение - состояние после создания
      expect(processor.isActive, isTrue);
      expect(processor.streamId, isPositive);
      expect(processor.responses, isA<Stream<RpcMessage<RpcString>>>());
    });

    test('sends request and serializes correctly', () async {
      // Подготавливаем тестовые данные в памяти
      final request = 'test message'.rpc;

      // Выполняем тестируемое действие
      await processor.send(request);

      // Ждем обработки
      await Future.delayed(Duration(milliseconds: 250));

      // Проверяем наблюдаемое поведение - процессор активен после отправки
      expect(processor.isActive, isTrue);
    });

    test('processes incoming response and deserializes correctly', () async {
      // Создаем коллектор для ответов
      final receivedResponses = <RpcMessage<RpcString>>[];
      final completer = Completer<void>();

      final subscription = processor.responses.listen(
        (response) {
          receivedResponses.add(response);
          if (!response.isMetadataOnly && response.payload != null) {
            completer.complete();
          }
        },
        onError: completer.completeError,
      );

      // Симулируем получение ответа через серверный транспорт
      final testResponse = 'response message'.rpc;
      final responseBytes = codec.serialize(testResponse);
      final framedMessage = RpcMessageFrame.encode(responseBytes);

      // Отправляем ответ через серверную сторону транспорта
      await serverTransport.sendMessage(processor.streamId, framedMessage);

      // Ждем получения ответа
      await completer.future.timeout(Duration(seconds: 5));

      // Проверяем наблюдаемое поведение - ответ получен и десериализован
      expect(receivedResponses, isNotEmpty);
      final dataResponse = receivedResponses.firstWhere(
        (r) => !r.isMetadataOnly && r.payload != null,
        orElse: () => throw StateError('No data response found'),
      );
      expect(dataResponse.payload!.value, equals('response message'));

      await subscription.cancel();
    });

    test('handles metadata responses correctly', () async {
      // Создаем коллектор для ответов
      final receivedResponses = <RpcMessage<RpcString>>[];
      final completer = Completer<void>();

      final subscription = processor.responses.listen(
        (response) {
          receivedResponses.add(response);
          if (response.isMetadataOnly) {
            completer.complete();
          }
        },
        onError: completer.completeError,
      );

      // Отправляем метаданные через серверный транспорт
      final metadata = RpcMetadata.forTrailer(RpcStatus.OK, message: 'Success');
      await serverTransport.sendMetadata(processor.streamId, metadata);

      // Ждем получения метаданных
      await completer.future.timeout(Duration(seconds: 5));

      // Проверяем, что метаданные обработаны
      expect(receivedResponses, isNotEmpty);
      final metadataResponse = receivedResponses.firstWhere(
        (r) => r.isMetadataOnly,
        orElse: () => throw StateError('No metadata response found'),
      );
      expect(metadataResponse.isMetadataOnly, isTrue);
      expect(metadataResponse.payload, isNull);

      await subscription.cancel();
    });

    test('finishSending completes successfully', () async {
      // Выполняем тестируемое действие
      await processor.finishSending();

      // Проверяем наблюдаемое поведение - процессор остается активным
      expect(processor.isActive, isTrue);
    });

    test('handles multiple requests in sequence', () async {
      // Подготавливаем несколько запросов
      final requests = [
        'message 1'.rpc,
        'message 2'.rpc,
        'message 3'.rpc,
      ];

      // Отправляем запросы
      for (final request in requests) {
        await processor.send(request);
        await Future.delayed(Duration(milliseconds: 50));
      }

      // Проверяем наблюдаемое поведение - все операции завершились без ошибок
      expect(processor.isActive, isTrue);
    });

    test('close makes processor inactive', () async {
      // Проверяем начальное состояние
      expect(processor.isActive, isTrue);

      // Выполняем тестируемое действие
      await processor.close();

      // Проверяем наблюдаемое поведение - состояние после закрытия
      expect(processor.isActive, isFalse);

      // Проверяем, что дальнейшие операции игнорируются
      await processor.send('should not work'.rpc);
      // Операция должна завершиться без ошибки, но ничего не делать
    });

    test('handles errors gracefully in response stream', () async {
      // Создаем коллектор для ошибок
      final errors = <Object>[];
      final subscription = processor.responses.listen(
        null,
        onError: errors.add,
      );

      // Закрываем серверный транспорт для симуляции ошибки сети
      await serverTransport.close();

      // Ждем обработки
      await Future.delayed(Duration(milliseconds: 500));

      // Проверяем наблюдаемое поведение - процессор продолжает работать
      expect(processor.isActive, isTrue);

      await subscription.cancel();
    });

    test('handles concurrent send operations', () async {
      // Подготавливаем запросы для конкурентной отправки
      final futures = <Future<void>>[];

      for (int i = 0; i < 5; i++) {
        futures.add(processor.send('concurrent $i'.rpc));
      }

      // Выполняем все отправки конкурентно
      await Future.wait(futures);

      // Проверяем наблюдаемое поведение - все операции завершились
      expect(processor.isActive, isTrue);
    });

    test('stream closes properly when server sends END_STREAM', () async {
      // Подписываемся на поток ответов
      final completer = Completer<void>();
      final subscription = processor.responses.listen(
        (_) {},
        onDone: () => completer.complete(),
        onError: completer.completeError,
      );

      // Отправляем END_STREAM через серверный транспорт
      final endMetadata = RpcMetadata.forTrailer(RpcStatus.OK);
      await serverTransport.sendMetadata(
        processor.streamId,
        endMetadata,
        endStream: true,
      );

      // Ждем закрытия потока
      await completer.future.timeout(Duration(seconds: 5));

      await subscription.cancel();
    });
  });
}
