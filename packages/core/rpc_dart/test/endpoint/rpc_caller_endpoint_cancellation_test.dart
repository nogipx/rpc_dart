// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

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

/// Тестовый контракт для responder с долгими операциями
final class TestService extends RpcResponderContract {
  final List<String> callLog = [];

  TestService() : super('TestService');

  @override
  void setup() {
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'SlowMethod',
      handler: (request, {context}) async {
        callLog.add('SlowMethod started: ${request.message}');

        // Симулируем долгую операцию с проверкой отмены
        for (int i = 0; i < 100; i++) {
          context?.cancellationToken?.throwIfCancelled();
          await Future.delayed(Duration(milliseconds: 10));
        }

        callLog.add('SlowMethod completed: ${request.message}');
        return TestResponse('Completed: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
    addServerStreamMethod<TestRequest, TestResponse>(
      methodName: 'SlowStreamMethod',
      handler: (request, {context}) async* {
        callLog.add('SlowStreamMethod started: ${request.message}');

        for (int i = 0; i < 10; i++) {
          context?.cancellationToken?.throwIfCancelled();
          yield TestResponse('Item $i for: ${request.message}');
          await Future.delayed(Duration(milliseconds: 50));
        }

        callLog.add('SlowStreamMethod completed: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
    addUnaryMethod<TestRequest, TestResponse>(
      methodName: 'FastMethod',
      handler: (request, {context}) async {
        callLog.add('FastMethod: ${request.message}');
        return TestResponse('Fast reply to: ${request.message}');
      },
      requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
      responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
    );
  }
}

void main() {
  group('RpcCallerEndpoint Cancellation Tests', () {
    late RpcCallerEndpoint callerEndpoint;
    late RpcResponderEndpoint responderEndpoint;
    late TestService testService;

    setUp(() async {
      // Создаем пару транспортов
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

      // Создаем эндпоинты
      callerEndpoint = RpcCallerEndpoint(transport: clientTransport);
      responderEndpoint = RpcResponderEndpoint(transport: serverTransport);

      // Создаем и регистрируем тестовый сервис
      testService = TestService();
      responderEndpoint.registerServiceContract(testService);
      responderEndpoint.start();
    });

    tearDown(() async {
      await responderEndpoint.close();
      await callerEndpoint.close();
      testService.callLog.clear();
    });

    test('Отмена унарного метода по ключу', () async {
      final future = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'FastMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation 1'),
      );

      callerEndpoint.cancelMethod('TestService', 'FastMethod');

      await expectLater(future, throwsA(isA<RpcCancelledException>()));
    });

    test('Отмена всех методов сервиса', () async {
      // Запускаем несколько методов
      final future1 = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation 1'),
      );

      final future2 = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'FastMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation 2'),
      );

      // Ждем немного
      await Future.delayed(Duration(milliseconds: 50));

      // Отменяем все методы сервиса
      callerEndpoint.cancelServiceMethods('TestService', 'Service shutdown');

      // Проверяем, что первый метод получил отмену
      await expectLater(
        future1,
        throwsA(
          predicate<RpcCancelledException>(
            (e) => e.message == 'Service shutdown',
          ),
        ),
      );

      // FastMethod может успеть выполниться до отмены - проверяем любой результат
      try {
        await future2;
      } on RpcCancelledException {
        // Ожидаемо, если метод был отменен
      }
    });

    test('Отмена всех активных методов', () async {
      // Запускаем метод
      final future = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation'),
      );

      // Ждем немного
      await Future.delayed(Duration(milliseconds: 50));

      // Отменяем все методы
      callerEndpoint.cancelAllMethods('Global cancellation');

      // Проверяем отмену
      await expectLater(
        future,
        throwsA(
          predicate<RpcCancelledException>(
            (e) => e.message == 'Global cancellation',
          ),
        ),
      );
    });

    test('Попытка отмены несуществующего метода', () async {
      // Пытаемся отменить метод, который не запущен
      final cancelled = callerEndpoint.cancelMethod(
        'TestService',
        'NonExistentMethod',
      );
      expect(cancelled, 0); // Теперь возвращает количество отмененных токенов
    });

    test(
      'Проверка токенов отмены через getCancellationTokensForMethod',
      () async {
        // Запускаем метод
        final future = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
          serviceName: 'TestService',
          methodName: 'SlowMethod',
          requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
          responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
          request: TestRequest('operation'),
        );

        // Проверяем количество активных вызовов
        final activeCallsCount = callerEndpoint
            .getCancellationTokensForMethod('TestService', 'SlowMethod')
            .length;
        expect(activeCallsCount, 1);

        // Отменяем все вызовы метода
        final cancelledCount = callerEndpoint.cancelMethod(
          'TestService',
          'SlowMethod',
        );
        expect(cancelledCount, 1);

        // Проверяем, что больше нет активных вызовов
        final activeCallsCountAfter = callerEndpoint
            .getCancellationTokensForMethod('TestService', 'SlowMethod')
            .length;
        expect(activeCallsCountAfter, 0);

        // Проверяем исключение
        await expectLater(
          future,
          throwsA(
            predicate<RpcCancelledException>(
              (e) => e.message == 'Method cancelled by user',
            ),
          ),
        );
      },
    );

    test('Множественные вызовы одного метода с разными токенами', () async {
      // Запускаем несколько вызовов одного метода
      final future1 = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation 1'),
      );

      // Добавляем небольшую задержку между запросами
      await Future.delayed(Duration(milliseconds: 10));

      final future2 = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation 2'),
      );

      // Ждем достаточно времени, чтобы оба запроса зарегистрировались
      await Future.delayed(Duration(milliseconds: 100));

      // Проверяем, что у нас есть 2 токена для одного метода
      final tokens = callerEndpoint.getCancellationTokensForMethod(
        'TestService',
        'SlowMethod',
      );
      expect(tokens.length, 2);

      // Отменяем все вызовы метода
      final cancelledCount = callerEndpoint.cancelMethod(
        'TestService',
        'SlowMethod',
      );
      expect(cancelledCount, 2);

      // Проверяем, что оба вызова отменены
      await expectLater(future1, throwsA(isA<RpcCancelledException>()));

      await expectLater(future2, throwsA(isA<RpcCancelledException>()));
    });

    test('Отмена с пользовательской причиной', () async {
      final future = callerEndpoint.unaryRequest<TestRequest, TestResponse>(
        serviceName: 'TestService',
        methodName: 'SlowMethod',
        requestCodec: RpcCodec<TestRequest>(TestRequest.fromJson),
        responseCodec: RpcCodec<TestResponse>(TestResponse.fromJson),
        request: TestRequest('operation'),
      );

      await Future.delayed(Duration(milliseconds: 50));

      final customReason = 'User clicked cancel button';
      callerEndpoint.cancelMethod('TestService', 'SlowMethod', customReason);

      await expectLater(
        future,
        throwsA(
          predicate<RpcCancelledException>((e) => e.message == customReason),
        ),
      );
    });
  });
}
