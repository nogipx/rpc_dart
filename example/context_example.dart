// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';

/// Пример использования RpcContext для передачи метаданных,
/// аутентификации, таймаутов и отмены операций
void main() async {
  RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);

  final logger = RpcLogger('ContextExample');
  logger.info('🚀 Запуск примера RPC Context');

  // Создаем транспорты
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // Создаем серверный эндпоинт и регистрируем контракт
  final serverEndpoint = RpcResponderEndpoint(
    transport: serverTransport,
    debugLabel: 'Server',
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
  );

  final authService = AuthenticatedServiceResponder();
  serverEndpoint.registerServiceContract(authService);
  serverEndpoint.start();

  // Создаем клиентский эндпоинт
  final clientEndpoint = RpcCallerEndpoint(
    transport: clientTransport,
    debugLabel: 'Client',
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
  );

  final client = AuthenticatedServiceCaller(clientEndpoint);

  try {
    logger.info('\n=== 1. Простой вызов без контекста ===');
    final simpleResult = await client.getPublicData('Публичные данные'.rpc);
    logger.info('✅ Результат: $simpleResult');

    logger.info('\n=== 2. Вызов с аутентификацией ===');
    final authContext =
        RpcContextUtils.withBearerToken('super-secret-token-123');
    final authResult = await client.getPrivateData(
      'Приватные данные'.rpc,
      context: authContext,
    );
    logger.info('✅ Результат: $authResult');

    logger.info('\n=== 3. Вызов с таймаутом ===');
    try {
      final timeoutContext =
          RpcContext.withTimeout(Duration(milliseconds: 100));
      await client.getSlowData(
        'Медленные данные'.rpc,
        context: timeoutContext,
      );
    } catch (e) {
      logger.info('⏰ Получили timeout (это ожидалось): $e');
    }

    logger.info('\n=== 4. Вызов с отменой ===');
    try {
      final cancellationToken = CancellationToken();
      final cancelContext = RpcContext.withCancellation(cancellationToken);

      // Отменяем операцию через 50мс
      Timer(Duration(milliseconds: 50), () {
        logger.info('🛑 Отменяем операцию');
        cancellationToken.cancel('User requested cancellation');
      });

      await client.getLongRunningData(
        'Долгие данные'.rpc,
        context: cancelContext,
      );
    } catch (e) {
      logger.info('❌ Операция отменена (это ожидалось): $e');
    }

    logger.info('\n=== 5. Комплексный контекст ===');
    final complexContext = RpcContext.withHeaders({
      'user-id': '12345',
      'session-id': 'sess_abc123',
      'correlation-id': 'corr_xyz789',
    })
        .withTimeout(Duration(seconds: 30))
        .withTraceId('trace_complex_call')
        .withValue('feature-flags', ['feature-a', 'feature-b']);

    final complexResult = await client.getComplexData(
      'Сложные данные'.rpc,
      context: complexContext,
    );
    logger.info('✅ Сложный результат: $complexResult');
  } catch (e, stackTrace) {
    logger.error('❌ Ошибка при выполнении запросов',
        error: e, stackTrace: stackTrace);
  } finally {
    logger.info('🔄 Завершение работы');
    await serverEndpoint.close();
    await clientEndpoint.close();
  }
}

//
// СЕРВЕРНЫЙ КОНТРАКТ
//

abstract interface class IAuthenticatedServiceContract implements IRpcContract {
  Future<RpcString> getPublicData(RpcString message);
  Future<RpcString> getPrivateData(RpcString message);
  Future<RpcString> getSlowData(RpcString message);
  Future<RpcString> getLongRunningData(RpcString message);
  Future<RpcString> getComplexData(RpcString message);
}

final class AuthenticatedServiceResponder extends RpcResponderContract
    implements IAuthenticatedServiceContract {
  AuthenticatedServiceResponder() : super('AuthenticatedService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'GetPublicData',
      handler: _getPublicData,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Получает публичные данные без аутентификации',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'GetPrivateData',
      handler: _getPrivateData,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Получает приватные данные с проверкой токена',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'GetSlowData',
      handler: _getSlowData,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Медленная операция для тестирования таймаутов',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'GetLongRunningData',
      handler: _getLongRunningData,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Долгая операция для тестирования отмены',
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'GetComplexData',
      handler: _getComplexData,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Сложная операция с множественными проверками контекста',
    );
  }

  Future<RpcString> _getPublicData(
      RpcContext context, RpcString message) async {
    final logger = RpcLogger('PublicData');
    logger.info('📂 Получение публичных данных: $message');
    logger.info('🔍 Context: $context');

    await Future.delayed(Duration(milliseconds: 10));
    return 'PUBLIC: ${message.value}'.rpc;
  }

  Future<RpcString> _getPrivateData(
      RpcContext context, RpcString message) async {
    final logger = RpcLogger('PrivateData');
    logger.info('🔒 Получение приватных данных: $message');
    logger.info('🔍 Context: $context');

    // Проверяем аутентификацию
    final authHeader = context.getHeader('authorization');
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      throw RpcException(
          'Unauthorized: Missing or invalid authorization header');
    }

    final token = authHeader.substring(7); // Убираем "Bearer "
    if (token != 'super-secret-token-123') {
      throw RpcException('Unauthorized: Invalid token');
    }

    logger.info('✅ Токен валиден');
    await Future.delayed(Duration(milliseconds: 20));
    return 'PRIVATE: ${message.value}'.rpc;
  }

  Future<RpcString> _getSlowData(RpcContext context, RpcString message) async {
    final logger = RpcLogger('SlowData');
    logger.info('🐌 Получение медленных данных: $message');
    logger.info('🔍 Context: $context');

    // Проверяем deadline
    final remaining = context.remainingTime;
    if (remaining != null && remaining < Duration(milliseconds: 200)) {
      logger.warning('⏰ Недостаточно времени: ${remaining.inMilliseconds}мс');
      throw RpcDeadlineExceededException(
          context.deadline!, Duration(milliseconds: 200));
    }

    // Имитируем медленную операцию
    await Future.delayed(Duration(milliseconds: 200));

    // Проверяем не истек ли deadline
    if (context.isExpired) {
      throw RpcDeadlineExceededException(
          context.deadline!, Duration(milliseconds: 200));
    }

    return 'SLOW: ${message.value}'.rpc;
  }

  Future<RpcString> _getLongRunningData(
      RpcContext context, RpcString message) async {
    final logger = RpcLogger('LongRunningData');
    logger.info('⏳ Получение данных с долгой обработкой: $message');
    logger.info('🔍 Context: $context');

    // Выполняем операцию с проверкой отмены
    for (int i = 0; i < 100; i++) {
      // Проверяем не отменена ли операция
      context.cancellationToken?.throwIfCancelled();

      await Future.delayed(Duration(milliseconds: 10));

      if (i % 20 == 0) {
        logger.debug('📊 Прогресс: ${i}%');
      }
    }

    return 'LONG_RUNNING: ${message.value}'.rpc;
  }

  Future<RpcString> _getComplexData(
      RpcContext context, RpcString message) async {
    final logger = RpcLogger('ComplexData');
    logger.info('🎛️ Получение сложных данных: $message');
    logger.info('🔍 Context: $context');

    // Проверяем различные части контекста
    final userId = context.getHeader('user-id');
    final sessionId = context.getHeader('session-id');
    final correlationId = context.getHeader('correlation-id');
    final featureFlags = context.getValue<List<String>>('feature-flags');

    logger.info('👤 User ID: $userId');
    logger.info('🎯 Session ID: $sessionId');
    logger.info('🔗 Correlation ID: $correlationId');
    logger.info('🚩 Feature flags: $featureFlags');
    logger.info('🆔 Trace ID: ${context.traceId}');
    logger.info('📝 Request ID: ${context.requestId}');

    await Future.delayed(Duration(milliseconds: 30));

    final result = {
      'data': message.value,
      'processed_by_user': userId,
      'session': sessionId,
      'correlation': correlationId,
      'features': featureFlags?.join(','),
      'trace': context.traceId,
    };

    return 'COMPLEX: ${result.toString()}'.rpc;
  }

  // Реализуем интерфейсные методы (они не будут вызываться напрямую)
  @override
  Future<RpcString> getPublicData(RpcString message) =>
      throw UnimplementedError();

  @override
  Future<RpcString> getPrivateData(RpcString message) =>
      throw UnimplementedError();

  @override
  Future<RpcString> getSlowData(RpcString message) =>
      throw UnimplementedError();

  @override
  Future<RpcString> getLongRunningData(RpcString message) =>
      throw UnimplementedError();

  @override
  Future<RpcString> getComplexData(RpcString message) =>
      throw UnimplementedError();
}

//
// КЛИЕНТСКИЙ КОНТРАКТ
//

final class AuthenticatedServiceCaller extends RpcCallerContract
    implements IAuthenticatedServiceContract {
  AuthenticatedServiceCaller(RpcCallerEndpoint endpoint)
      : super('AuthenticatedService', endpoint);

  @override
  Future<RpcString> getPublicData(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'GetPublicData',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> getPrivateData(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'GetPrivateData',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> getSlowData(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'GetSlowData',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> getLongRunningData(RpcString message,
      {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'GetLongRunningData',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }

  @override
  Future<RpcString> getComplexData(RpcString message, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'GetComplexData',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: message,
      context: context,
    );
  }
}
