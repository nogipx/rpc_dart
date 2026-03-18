// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await UnaryRpcExample.run();
}

/// Пример использования унарного RPC вызова (один запрос - один ответ)
/// с использованием новых контрактов и RpcContext
class UnaryRpcExample {
  static Future<void> run() async {
    RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.debug);
    print('\n=== Пример унарного RPC с контрактами и контекстом ===\n');

    // Создаем транспорты
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

    // Создаем серверный эндпоинт и регистрируем контракты
    final serverEndpoint = RpcResponderEndpoint(
      transport: serverTransport,
      debugLabel: 'Server',
      loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
    );

    final multiService = MultiServiceResponder();
    serverEndpoint.registerServiceContract(multiService);
    serverEndpoint.start();

    // Создаем клиентский эндпоинт
    final clientEndpoint = RpcCallerEndpoint(
      transport: clientTransport,
      debugLabel: 'Client',
      loggerColors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
    );

    final client = MultiServiceCaller(clientEndpoint);

    try {
      // Пример 1: Простой вызов без контекста
      print('\n--- Пример 1: Простой вызов ---');
      final response1 = await client.sayHello('Привет'.rpc);
      print('КЛИЕНТ: Получен ответ: "$response1"');

      // Пример 2: Вызов с базовым контекстом
      print('\n--- Пример 2: Вызов с контекстом ---');
      final context2 = RpcContextUtils.withBearerToken('secret-token-123')
          .withAdditionalHeaders({'user-id': 'user-456'}).withTraceId(
              'trace-${DateTime.now().millisecondsSinceEpoch}');

      final response2 = await client.getCurrentTime(
        'Время'.rpc,
        context: context2,
      );
      print('КЛИЕНТ: Получен ответ: "$response2"');

      // Пример 3: Вызов с таймаутом
      print('\n--- Пример 3: Вызов с таймаутом ---');
      final timeoutContext = RpcContext.withTimeout(
        Duration(milliseconds: 500),
      ).withValue('request-type', 'health-check');

      final response3 = await client.checkHealth(
        'Статус'.rpc,
        context: timeoutContext,
      );
      print('КЛИЕНТ: Получен ответ: "$response3"');

      // Пример 4: Вызов с ошибкой
      print('\n--- Пример 4: Обработка ошибок ---');
      try {
        await client.throwError('Ошибка'.rpc);
      } catch (e) {
        print('КЛИЕНТ: Получена ожидаемая ошибка: $e');
      }

      // Пример 5: Вызов с отменой
      print('\n--- Пример 5: Отмена операции ---');
      try {
        final cancellationToken = RpcCancellationToken();
        final cancelContext = RpcContext.withCancellation(cancellationToken);

        // Отменяем через 100мс
        Future.delayed(Duration(milliseconds: 100), () {
          print('КЛИЕНТ: Отменяем операцию');
          cancellationToken.cancel('User cancelled');
        });

        await client.longOperation(
          'Долгая операция'.rpc,
          context: cancelContext,
        );
      } catch (e) {
        print('КЛИЕНТ: Операция отменена: $e');
      }
    } catch (e, stackTrace) {
      print('ОШИБКА: $e');
      print('StackTrace: $stackTrace');
    } finally {
      await serverEndpoint.close();
      await clientEndpoint.close();
    }

    print('\n=== Пример завершен ===\n');
  }
}

//
// СЕРВЕРНЫЙ КОНТРАКТ
//

abstract interface class IMultiServiceContract implements IRpcContract {
  Future<RpcString> sayHello(RpcString message);
  Future<RpcString> getCurrentTime(RpcString message);
  Future<RpcString> checkHealth(RpcString message);
  Future<RpcString> throwError(RpcString message);
  Future<RpcString> longOperation(RpcString message);
}

final class MultiServiceResponder extends RpcResponderContract
    implements IMultiServiceContract {
  MultiServiceResponder() : super('MultiService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'SayHello',
      handler: sayHello,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Простое приветствие',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'GetCurrentTime',
      handler: getCurrentTime,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Получает текущее время',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'CheckHealth',
      handler: checkHealth,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Проверяет состояние сервиса',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ThrowError',
      handler: throwError,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Генерирует ошибку для тестирования',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'LongOperation',
      handler: longOperation,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Долгая операция для тестирования отмены',
    );
  }

  @override
  Future<RpcString> sayHello(RpcString message, {RpcContext? context}) async {
    final logger = RpcLogger('SayHello');
    logger.info('🔧 Получен запрос: ${message.value}');
    logger.info('🔍 Context: $context');

    await Future.delayed(Duration(milliseconds: 10));
    return 'Здравствуйте! Это ответ от сервера: ${message.value}'.rpc;
  }

  @override
  Future<RpcString> getCurrentTime(
    RpcString message, {
    RpcContext? context,
  }) async {
    final logger = RpcLogger('GetCurrentTime');
    logger.info('🔧 Получен запрос времени: ${message.value}');
    logger.info('🔍 Context: $context');

    final userId = context?.getHeader('user-id');
    final traceId = context?.traceId;

    await Future.delayed(Duration(milliseconds: 20));
    return 'Текущее время: ${DateTime.now()} [user: $userId, trace: $traceId]'
        .rpc;
  }

  @override
  Future<RpcString> checkHealth(
    RpcString message, {
    RpcContext? context,
  }) async {
    final logger = RpcLogger('CheckHealth');
    logger.info('🔧 Проверка здоровья: ${message.value}');
    logger.info('🔍 Context: $context');

    final requestType = context?.getValue<String>('request-type');
    context?.cancellationToken?.throwIfCancelled();

    await Future.delayed(Duration(milliseconds: 30));
    return 'Все системы работают нормально [$requestType]'.rpc;
  }

  @override
  Future<RpcString> throwError(RpcString message, {RpcContext? context}) async {
    final logger = RpcLogger('ThrowError');
    logger.info('🔧 Генерируем ошибку: ${message.value}');
    logger.info('🔍 Context: $context');

    throw Exception('Тестовая ошибка: ${message.value}');
  }

  @override
  Future<RpcString> longOperation(
    RpcString message, {
    RpcContext? context,
  }) async {
    final logger = RpcLogger('LongOperation');
    logger.info('🔧 Начинаем долгую операцию: ${message.value}');
    logger.info('🔍 Context: $context');

    for (int i = 0; i < 100; i++) {
      context?.cancellationToken?.throwIfCancelled();
      await Future.delayed(Duration(milliseconds: 10));

      if (i % 20 == 0) {
        logger.internal('📊 Прогресс: $i%');
      }
    }

    return 'Долгая операция завершена: ${message.value}'.rpc;
  }
}

//
// КЛИЕНТСКИЙ КОНТРАКТ
//

final class MultiServiceCaller extends RpcCallerContract
    implements IMultiServiceContract {
  MultiServiceCaller(RpcCallerEndpoint endpoint)
      : super('MultiService', endpoint);

  @override
  Future<RpcString> sayHello(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'SayHello',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> getCurrentTime(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'GetCurrentTime',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> checkHealth(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'CheckHealth',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> throwError(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'ThrowError',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> longOperation(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'LongOperation',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }
}
