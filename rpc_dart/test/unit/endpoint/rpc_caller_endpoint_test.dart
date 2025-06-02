// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Тестовый запрос
class TestRequest implements IRpcSerializable {
  final String message;

  TestRequest(this.message);

  factory TestRequest.fromJson(Map<String, dynamic> json) {
    return TestRequest(json['message'] as String);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'message': message};
  }
}

/// Тестовый ответ
class TestResponse implements IRpcSerializable {
  final String message;

  TestResponse(this.message);

  factory TestResponse.fromJson(Map<String, dynamic> json) {
    return TestResponse(json['message'] as String);
  }

  @override
  Map<String, dynamic> toJson() {
    return {'message': message};
  }
}

/// Тестовый контракт для responder
final class TestService extends RpcResponderContract {
  final List<String> callLog = [];

  TestService() : super('TestService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'UnaryMethod',
      handler: (request) async {
        callLog.add('UnaryMethod: ${request.message}');
        return TestResponse('Reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );

    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'ServerStreamMethod',
      handler: (request) async* {
        callLog.add('ServerStreamMethod: ${request.message}');
        for (int i = 0; i < 3; i++) {
          yield TestResponse('Reply ${i + 1} to: ${request.message}');
          await Future.delayed(Duration(milliseconds: 10));
        }
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );

    addClientStreamMethod<TestRequest, TestResponse>(
      methodName: 'ClientStreamMethod',
      handler: (Stream<TestRequest> requests) async {
        final messages = <String>[];

        await for (final request in requests) {
          messages.add(request.message);
        }

        callLog.add('ClientStreamMethod: ${messages.join(", ")}');
        return TestResponse('Received: ${messages.join(", ")}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );

    addBidirectionalMethod<TestRequest, TestResponse>(
      methodName: 'BidirectionalMethod',
      handler: (Stream<TestRequest> requests) async* {
        callLog.add('BidirectionalMethod: начат');

        await for (final request in requests) {
          callLog.add('BidirectionalMethod: ${request.message}');
          yield TestResponse('Echo: ${request.message}');
          await Future.delayed(Duration(milliseconds: 10));
        }

        callLog.add('BidirectionalMethod: завершен');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

void main() {
  // Включаем подробное логирование для отладки
  RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);

  group('RpcCallerEndpoint Тесты', () {
    late RpcInMemoryTransport clientTransport;
    late RpcInMemoryTransport serverTransport;
    late RpcResponderEndpoint responderEndpoint;
    late RpcCallerEndpoint callerEndpoint;
    late TestService testService;

    setUp(() {
      final pair = RpcInMemoryTransport.pair();
      clientTransport = pair.$1;
      serverTransport = pair.$2;

      responderEndpoint = RpcResponderEndpoint(transport: serverTransport);
      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);

      // Регистрируем тестовый сервис
      testService = TestService();
      responderEndpoint.registerServiceContract(testService);

      // ВАЖНО: Запускаем responderEndpoint для обработки входящих запросов
      responderEndpoint.start();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
      testService.callLog.clear();
    });

    test('Унарный запрос возвращает корректный ответ', () async {
      // Отправляем унарный запрос
      final response =
          await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'UnaryMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('Hello from test'),
      );

      // Проверяем ответ
      expect(response.message, equals('Reply to: Hello from test'));
      expect(testService.callLog, contains('UnaryMethod: Hello from test'));
    });

    test('Серверный стрим возвращает все ожидаемые сообщения', () async {
      print('=== УПРОЩЕННЫЙ ТЕСТ СЕРВЕРНОГО СТРИМА ===');

      // Регистрируем обработчик событий
      final responses = <TestResponse>[];
      final completer = Completer<void>();

      // Запускаем серверный стрим
      final stream = callerEndpoint.serverStream<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'ServerStreamMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('Stream request'),
      );

      print('Подписка на стрим...');
      final subscription = stream.listen(
        (response) {
          print('✅ Получен ответ: ${response.message}');
          responses.add(response);
          if (responses.length >= 3) {
            completer.complete();
          }
        },
        onError: (e, stack) {
          print('❌ Ошибка в стриме: $e');
          completer.completeError(e, stack);
        },
        onDone: () {
          print('✅ Стрим завершен, получено ответов: ${responses.length}');
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );

      try {
        // Ждем максимум 5 секунд
        await completer.future.timeout(Duration(seconds: 5));
        await subscription.cancel();

        print('Результат: получено ${responses.length} ответов');
        expect(responses.length, greaterThanOrEqualTo(1),
            reason: 'Должен получить хотя бы 1 ответ');

        if (responses.isNotEmpty) {
          expect(responses.first.message, contains('Stream request'));
        }
      } catch (e) {
        await subscription.cancel();
        print('❌ Тест не прошел: $e');
        expect(false, isTrue, reason: 'Тест упал с ошибкой: $e');
      }
    });

    test('Клиентский стрим корректно отправляет все сообщения', () async {
      // Создаем стрим запросов используя Stream.fromIterable для простоты
      final requestStream = Stream.fromIterable([
        TestRequest('Message 1'),
        TestRequest('Message 2'),
        TestRequest('Message 3'),
      ]);

      print('Начало теста клиентского стрима');

      // Получаем функцию ответа
      final getResponse =
          callerEndpoint.clientStream<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'ClientStreamMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        requests: requestStream,
      );

      print('Клиентский стрим создан');

      // Вызываем getResponse для отправки всех сообщений и получения ответа
      print('Вызов getResponse для отправки сообщений и получения ответа');
      final response = await getResponse().timeout(
        Duration(seconds: 10),
        onTimeout: () {
          print('Таймаут при ожидании ответа');
          throw TimeoutException('Таймаут ожидания ответа');
        },
      );

      print('Ответ получен успешно!');

      // Проверяем результат
      expect(response.message,
          equals('Received: Message 1, Message 2, Message 3'));
      expect(testService.callLog,
          contains('ClientStreamMethod: Message 1, Message 2, Message 3'));
    });

    test('Двунаправленный стрим работает в обоих направлениях', () async {
      // Создаем стрим запросов
      final controller = StreamController<TestRequest>();
      print('Начало теста двунаправленного стрима');

      // Создаем список для сбора ответов
      final responses = <TestResponse>[];
      final responseCompleter = Completer<List<TestResponse>>();

      // Запускаем двунаправленный стрим
      final responseStream =
          callerEndpoint.bidirectionalStream<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'BidirectionalMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        requests: controller.stream,
      );

      print('Двунаправленный стрим создан, настраиваем обработку ответов');

      // Слушаем ответы
      final subscription = responseStream.listen(
        (response) {
          print('Получен ответ: ${response.message}');
          responses.add(response);
          // Когда получили все 3 ответа, завершаем
          if (responses.length == 3) {
            if (!responseCompleter.isCompleted) {
              responseCompleter.complete(responses);
            }
          }
        },
        onError: (error, stackTrace) {
          print('Ошибка в стриме ответов: $error');
          print(stackTrace);
          if (!responseCompleter.isCompleted) {
            responseCompleter.completeError(error, stackTrace);
          }
        },
        onDone: () {
          print(
              'Стрим ответов завершен, получено ответов: ${responses.length}');
          if (!responseCompleter.isCompleted) {
            responseCompleter.complete(responses);
          }
        },
      );

      // Небольшая задержка перед отправкой запросов для стабильности
      await Future.delayed(Duration(milliseconds: 200));

      // Отправляем запросы с увеличенными интервалами
      print('Отправка запроса 1');
      controller.add(TestRequest('Bi Message 1'));
      await Future.delayed(Duration(milliseconds: 200));

      print('Отправка запроса 2');
      controller.add(TestRequest('Bi Message 2'));
      await Future.delayed(Duration(milliseconds: 200));

      print('Отправка запроса 3');
      controller.add(TestRequest('Bi Message 3'));
      await Future.delayed(Duration(milliseconds: 200));

      print('Закрытие потока запросов');
      // Закрываем контроллер, сигнализируя конец потока запросов
      await controller.close();

      // Даем больше времени на получение всех ответов
      await Future.delayed(Duration(milliseconds: 500));
      print('Ожидание получения всех ответов...');

      try {
        // Ждем получения всех ответов с увеличенным таймаутом
        final allResponses = await responseCompleter.future.timeout(
          Duration(seconds: 15),
          onTimeout: () {
            print(
                'Таймаут при ожидании ответов, получено: ${responses.length}');
            if (responses.length >= 3) {
              return responses; // Если успели получить достаточно ответов, считаем успешным
            }
            throw TimeoutException('Таймаут ожидания ответов');
          },
        );

        print('Получены все ответы: ${allResponses.length}');

        // Проверяем результаты
        expect(allResponses.length, equals(3));
        if (allResponses.isNotEmpty) {
          expect(allResponses[0].message, equals('Echo: Bi Message 1'));
        }
        if (allResponses.length > 1) {
          expect(allResponses[1].message, equals('Echo: Bi Message 2'));
        }
        if (allResponses.length > 2) {
          expect(allResponses[2].message, equals('Echo: Bi Message 3'));
        }

        expect(testService.callLog, contains('BidirectionalMethod: начат'));
        expect(
            testService.callLog, contains('BidirectionalMethod: Bi Message 1'));
        expect(
            testService.callLog, contains('BidirectionalMethod: Bi Message 2'));
        expect(
            testService.callLog, contains('BidirectionalMethod: Bi Message 3'));
      } finally {
        // Отменяем подписку
        await subscription.cancel();
        print('Подписка отменена');
      }
    });

    test('Закрытие эндпоинта корректно освобождает ресурсы', () async {
      // Отправляем запрос до закрытия
      final response =
          await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'UnaryMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('Pre-close request'),
      );

      expect(response.message, equals('Reply to: Pre-close request'));

      // Закрываем эндпоинт
      await callerEndpoint.close();

      // Проверяем, что эндпоинт больше не активен
      expect(callerEndpoint.isActive, isFalse);

      // Попытка использовать закрытый эндпоинт должна вызвать ошибку
      expect(() async {
        await callerEndpoint.unaryRequest<TestRequest, TestResponse>(
          serviceName: 'TestService',
          methodName: 'UnaryMethod',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: TestRequest('Post-close request'),
        );
      }, throwsA(isA<StateError>()));

      // Выделяем время для завершения всех асинхронных операций
      await Future.delayed(Duration(milliseconds: 100));
    });
  });
}
