// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class TestRequest implements IRpcSerializable {
  final String message;

  TestRequest(this.message);

  @override
  Map<String, dynamic> toJson() => {'message': message};

  static TestRequest fromJson(Map<String, dynamic> json) =>
      TestRequest(json['message']);

  @override
  String toString() => 'TestRequest($message)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TestRequest && message == other.message;

  @override
  int get hashCode => message.hashCode;
}

class TestResponse implements IRpcSerializable {
  final String result;

  TestResponse(this.result);

  @override
  Map<String, dynamic> toJson() => {'result': result};

  static TestResponse fromJson(Map<String, dynamic> json) =>
      TestResponse(json['result']);

  @override
  String toString() => 'TestResponse($result)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TestResponse && result == other.result;

  @override
  int get hashCode => result.hashCode;
}

final class StreamingTestService extends RpcResponderContract {
  StreamingTestService() : super('StreamingTestService');

  @override
  void setup() {
    // 🚀 ZERO-COPY: Server Stream Method - отправляем поток ответов на один запрос
    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'GetNumbers',
      handler: (request, {context}) async* {
        final count = int.tryParse(request.message) ?? 3;
        for (int i = 1; i <= count; i++) {
          yield TestResponse('Number $i for: ${request.message}');
          await Future.delayed(Duration(milliseconds: 1));
        }
      },
      // ✅ НЕ передаем кодеки → автоматически zero-copy режим
      description: 'Zero-copy server stream для генерации чисел',
    );

    // 🚀 ZERO-COPY: Client Stream Method - получаем поток запросов, отправляем один ответ
    addClientStreamMethod<TestRequest, TestResponse>(
      methodName: 'ProcessItems',
      handler: (requests, {context}) async {
        final items = <String>[];
        await for (final request in requests) {
          items.add(request.message);
        }
        return TestResponse(
          'Processed ${items.length} items: ${items.join(", ")}',
        );
      },
      // ✅ НЕ передаем кодеки → автоматически zero-copy режим
      description: 'Zero-copy client stream для обработки элементов',
    );

    // 🚀 ZERO-COPY: Bidirectional Stream Method - поток в обе стороны
    addBidirectionalMethod<TestRequest, TestResponse>(
      methodName: 'Chat',
      handler: (requests, {context}) async* {
        await for (final request in requests) {
          if (request.message.startsWith('ping')) {
            yield TestResponse('pong');
          } else {
            yield TestResponse('echo: ${request.message}');
          }
          await Future.delayed(Duration(milliseconds: 1));
        }
      },
      // ✅ НЕ передаем кодеки → автоматически zero-copy режим
      description: 'Zero-copy bidirectional stream для чата',
    );
  }
}

void main() {
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.info);

  group('🚀 Zero-Copy Streams Tests', () {
    late RpcResponderEndpoint serverEndpoint;
    late RpcCallerEndpoint clientEndpoint;
    late StreamingTestService testService;
    late IRpcTransport clientTransport;
    late IRpcTransport serverTransport;
    final sentMessages = <RpcTransportMessage>[];

    setUp(() async {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      serverEndpoint = RpcResponderEndpoint(transport: serverTransport);
      testService = StreamingTestService();
      serverEndpoint.registerServiceContract(testService);
      serverEndpoint.start();

      clientEndpoint = RpcCallerEndpoint(transport: clientTransport);

      // Мониторим все сообщения
      sentMessages.clear();
      serverTransport.incomingMessages.listen((message) {
        sentMessages.add(message);

        if (message.isSerialized && message.payload != null) {
          print('\n📡 СЕРИАЛИЗАЦИЯ обнаружена!');
          print('   Размер: ${message.payload!.length} bytes');
          print('   Stream ID: ${message.streamId}');
          print('   Type: ${message.runtimeType}');
        } else if (message.isDirect && message.directPayload != null) {
          print('\n🚀 ZERO-COPY обнаружен!');
          print('   Объект: ${message.directPayload.runtimeType}');
          print('   Stream ID: ${message.streamId}');
          print('   Data: ${message.directPayload}');
        }
      });
    });

    tearDown(() async {
      await clientEndpoint.close();
      await serverEndpoint.close();
    });

    test('🚀 Server Stream с Zero-Copy', () async {
      print('\n📋 === SERVER STREAM ZERO-COPY TEST ===');

      final request = TestRequest('3');

      // Выполняем server stream вызов БЕЗ КОДЕКОВ для zero-copy
      final responses = <TestResponse>[];
      await for (final response
          in clientEndpoint.serverStream<TestRequest, TestResponse>(
        serviceName: 'StreamingTestService',
        methodName: 'GetNumbers',
        // ✅ НЕ передаем кодеки → автоматически zero-copy режим
        request: request,
      )) {
        responses.add(response);
        print('📥 Получен ответ: ${response.result}');
      }

      // Ждем обработки всех сообщений
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

      expect(responses.length, equals(3));
      expect(responses[0].result, equals('Number 1 for: 3'));
      expect(responses[1].result, equals('Number 2 for: 3'));
      expect(responses[2].result, equals('Number 3 for: 3'));

      // Проверяем zero-copy
      expect(
        directMessages,
        greaterThan(0),
        reason: 'Ожидаем zero-copy сообщения',
      );
      print(
        directMessages > 0
            ? '\n✅ Server Stream Zero-Copy работает!'
            : '\n❌ Zero-Copy НЕ работает',
      );
    });

    test('🚀 Client Stream с Zero-Copy', () async {
      print('\n📋 === CLIENT STREAM ZERO-COPY TEST ===');

      sentMessages.clear();

      // Создаем client stream
      final requestStream = Stream.fromIterable([
        TestRequest('item1'),
        TestRequest('item2'),
        TestRequest('item3'),
      ]);

      final response =
          await clientEndpoint.clientStream<TestRequest, TestResponse>(
        serviceName: 'StreamingTestService',
        methodName: 'ProcessItems',
        // ✅ НЕ передаем кодеки → автоматически zero-copy режим
      )(requestStream);

      print('📥 Получен итоговый ответ: ${response.result}');

      // Ждем обработки всех сообщений
      await Future.delayed(Duration(milliseconds: 1));

      print('\n📊 Анализ сообщений:');
      print('   Всего сообщений: ${sentMessages.length}');

      final serializedMessages =
          sentMessages.where((m) => m.isSerialized).length;
      final directMessages = sentMessages.where((m) => m.isDirect).length;

      print('   📡 Сериализованных: $serializedMessages');
      print('   🚀 Zero-copy: $directMessages');

      expect(response.result, equals('Processed 3 items: item1, item2, item3'));

      // Проверяем zero-copy
      expect(
        directMessages,
        greaterThan(0),
        reason: 'Ожидаем zero-copy сообщения',
      );
      print(
        directMessages > 0
            ? '\n✅ Client Stream Zero-Copy работает!'
            : '\n❌ Zero-Copy НЕ работает',
      );
    });

    test('🚀 Bidirectional Stream с Zero-Copy', () async {
      print('\n📋 === BIDIRECTIONAL STREAM ZERO-COPY TEST ===');

      sentMessages.clear();

      // Создаем bidirectional stream
      final requestController = StreamController<TestRequest>();
      final responses = <TestResponse>[];

      final responseStream =
          clientEndpoint.bidirectionalStream<TestRequest, TestResponse>(
        serviceName: 'StreamingTestService',
        methodName: 'Chat',
        // ✅ НЕ передаем кодеки → автоматически zero-copy режим
        requests: requestController.stream,
      );

      final subscription = responseStream.listen((response) {
        responses.add(response);
        print('📥 Получен ответ: ${response.result}');
      });

      // Отправляем несколько запросов
      requestController.add(TestRequest('ping 1'));
      await Future.delayed(Duration(milliseconds: 1));

      requestController.add(TestRequest('hello world'));
      await Future.delayed(Duration(milliseconds: 1));

      requestController.add(TestRequest('ping 2'));
      await Future.delayed(Duration(milliseconds: 1));

      await requestController.close();
      await Future.delayed(Duration(milliseconds: 1));

      print('\n📊 Анализ сообщений:');
      print('   Всего сообщений: ${sentMessages.length}');

      final serializedMessages =
          sentMessages.where((m) => m.isSerialized).length;
      final directMessages = sentMessages.where((m) => m.isDirect).length;

      print('   📡 Сериализованных: $serializedMessages');
      print('   🚀 Zero-copy: $directMessages');

      expect(responses.length, greaterThanOrEqualTo(3));
      expect(responses.any((r) => r.result == 'pong'), isTrue);
      expect(responses.any((r) => r.result == 'echo: hello world'), isTrue);

      // Проверяем zero-copy
      expect(
        directMessages,
        greaterThan(0),
        reason: 'Ожидаем zero-copy сообщения',
      );
      print(
        directMessages > 0
            ? '\n✅ Bidirectional Stream Zero-Copy работает!'
            : '\n❌ Zero-Copy НЕ работает',
      );

      await subscription.cancel();
    });

    test('🎯 Сравнение Zero-Copy vs Сериализация', () async {
      print('\n📋 === СРАВНЕНИЕ ПРОИЗВОДИТЕЛЬНОСТИ ===');

      // Тест для демонстрации эффективности zero-copy
      final largeRequest = TestRequest(
        'big data with lots of text that would take time to serialize and deserialize if we were not using zero-copy optimization for inmemory transport which allows us to pass objects by reference',
      );

      sentMessages.clear();
      final stopwatch = Stopwatch()..start();

      // Выполняем server stream с большими данными БЕЗ КОДЕКОВ
      final responses = <TestResponse>[];
      await for (final response
          in clientEndpoint.serverStream<TestRequest, TestResponse>(
        serviceName: 'StreamingTestService',
        methodName: 'GetNumbers',
        // ✅ НЕ передаем кодеки → автоматически zero-copy режим
        request: largeRequest,
      )) {
        responses.add(response);
      }

      stopwatch.stop();

      print(
        '⏱️ Время выполнения: ${stopwatch.elapsedMicroseconds} микросекунд',
      );

      final serializedMessages =
          sentMessages.where((m) => m.isSerialized).length;
      final directMessages = sentMessages.where((m) => m.isDirect).length;

      print('📊 Результаты:');
      print('   📡 Сериализованных сообщений: $serializedMessages');
      print('   🚀 Zero-copy сообщений: $directMessages');
      print(
        '   📈 Экономия на сериализации: ${directMessages > serializedMessages ? 'ЕСТЬ' : 'НЕТ'}',
      );

      expect(responses.length, equals(3));
      expect(directMessages, greaterThan(0));

      if (directMessages > serializedMessages) {
        print('\n🎉 ОТЛИЧНО! Zero-copy оптимизация работает для стримов!');
        print(
          '💡 Объекты передаются по ссылке без накладных расходов на сериализацию',
        );
      }
    });
  });
}
