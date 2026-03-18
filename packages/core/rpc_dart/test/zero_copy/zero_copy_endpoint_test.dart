// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// Тестовые модели
class TestRequest implements IRpcSerializable {
  final String message;
  final List<String> data;

  TestRequest(this.message, this.data);

  factory TestRequest.fromJson(Map<String, dynamic> json) {
    return TestRequest(
      json['message'] as String,
      (json['data'] as List).cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {'message': message, 'data': data};
  }
}

class TestResponse implements IRpcSerializable {
  final String result;
  final int count;

  TestResponse(this.result, this.count);

  factory TestResponse.fromJson(Map<String, dynamic> json) {
    return TestResponse(json['result'] as String, json['count'] as int);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'result': result, 'count': count};
  }
}

// Тестовый сервис
final class TestService extends RpcResponderContract {
  TestService() : super('TestService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'processData',
      handler: (request, {context}) async {
        // Симуляция обработки
        final processedData =
            request.data.map((item) => item.toUpperCase()).toList();
        return TestResponse(
          'Processed: ${request.message}. Items: ${processedData.join(", ")}',
          request.data.length,
        );
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

void main() {
  group('🔍 Zero-Copy Endpoint Анализ', () {
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    late RpcResponderEndpoint responderEndpoint;
    late RpcCallerEndpoint callerEndpoint;
    late TestService testService;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      responderEndpoint = RpcResponderEndpoint(transport: serverTransport);
      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);

      testService = TestService();
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
    });

    test('📊 Демонстрация текущей сериализации', () async {
      print('\n🔬 Анализ текущего поведения endpoint-ов...');

      // Создаем сложный объект для тестирования
      final request = TestRequest('Complex data processing', [
        'item1',
        'item2',
        'item3',
        'item4',
        'item5',
      ]);

      print('\n📤 Отправляем запрос через endpoint...');
      print('   Запрос: ${request.message}');
      print('   Данные: ${request.data}');

      // Трекаем что происходит на транспортном уровне
      final sentMessages = <RpcTransportMessage>[];

      // Подписываемся на входящие сообщения на сервере
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);

        if (message.isSerialized && message.payload != null) {
          print('\n📡 СЕРИАЛИЗАЦИЯ обнаружена!');
          print(
            '   Размер сериализованных данных: ${message.payload!.length} bytes',
          );
          print('   Stream ID: ${message.streamId}');
          print('   EndOfStream: ${message.isEndOfStream}');
        } else if (message.isDirect && message.directPayload != null) {
          print('\n🚀 ZERO-COPY обнаружен!');
          print('   Прямой объект: ${message.directPayload.runtimeType}');
          print('   Stream ID: ${message.streamId}');
          print('   EndOfStream: ${message.isEndOfStream}');
        } else if (message.metadata != null) {
          print('\n📋 Метаданные:');
          print('   Headers: ${message.metadata!.headers.length}');
          print('   EndOfStream: ${message.isEndOfStream}');
        }
      });

      // Выполняем RPC вызов через endpoint
      final response =
          await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'processData',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: request,
      );

      print('\n📥 Получен ответ:');
      print('   Результат: ${response.result}');
      print('   Количество: ${response.count}');

      // Ждем чтобы все сообщения были обработаны
      await Future.delayed(Duration(milliseconds: 1));

      print('\n📊 Анализ сообщений:');
      print('   Всего сообщений: ${sentMessages.length}');

      final serializedMessages =
          sentMessages.where((m) => m.isSerialized).length;
      final directMessages = sentMessages.where((m) => m.isDirect).length;
      final metadataMessages = sentMessages
          .where((m) => m.metadata != null && !m.isSerialized && !m.isDirect)
          .length;

      print('   📡 Сериализованных: $serializedMessages');
      print('   🚀 Zero-copy: $directMessages');
      print('   📋 Только метаданные: $metadataMessages');

      if (directMessages > 0) {
        print('\n✅ ОТЛИЧНО: Zero-copy работает в endpoint-ах!');
        print('🚀 Объекты передаются по ссылке без сериализации');
      } else if (serializedMessages > 0) {
        print(
          '\n⚠️ ПРОБЛЕМА: Все еще используется сериализация для inmemory транспорта!',
        );
        print('💡 Решение: Проверить реализацию zero-copy в endpoint-ах');
      }

      // Проверяем что вызов работает
      expect(response.result, contains('Processed: Complex data processing'));
      expect(response.count, equals(5));

      // Теперь ожидаем zero-copy для inmemory транспорта
      expect(
        directMessages,
        greaterThan(0),
        reason: 'Ожидаем zero-copy в новой реализации',
      );
      expect(
        serializedMessages,
        equals(0),
        reason: 'Не должно быть сериализации для inmemory транспорта',
      );
    });

    test('🎯 Идеальный Zero-Copy сценарий', () async {
      print('\n💭 Как ДОЛЖНО работать zero-copy в endpoint-ах:');
      print('   1. Endpoint определяет что используется RpcInMemoryTransport');
      print(
        '   2. Вместо serialize() + sendMessage() использует sendDirectObject()',
      );
      print(
        '   3. На receiving стороне получает directPayload без deserialize()',
      );
      print('   4. Объекты передаются по ссылке - ZERO накладных расходов');

      // Демонстрируем прямое использование zero-copy
      final request = TestRequest('Direct object', ['zero', 'copy', 'test']);

      // Прямое использование zero-copy на транспортном уровне
      if (clientTransport.supportsZeroCopy) {
        final transport = clientTransport as RpcInMemoryTransport;
        final streamId = transport.createStream();

        print('\n🚀 Прямой zero-copy вызов:');

        // ✅ ИСПРАВЛЕНИЕ: Подписываемся на сообщения ДО отправки
        final messagesFuture = serverTransport.incomingMessages
            .where((m) => m.streamId == streamId && m.isDirect)
            .first
            .timeout(Duration(seconds: 2)); // Добавляем таймаут для отладки

        // Теперь отправляем сообщение
        await transport.sendDirectObject(streamId, request, endStream: true);

        // Ждем сообщение
        final directMessage = await messagesFuture;

        expect(
          directMessage.directPayload,
          same(request),
          reason: 'Объект должен быть тем же самым (по ссылке)',
        );

        print('   ✅ Объект передан по ссылке без сериализации!');
        print('   ✅ Размер данных: 0 bytes (указатель на объект)');
      }
    });
  });
}
