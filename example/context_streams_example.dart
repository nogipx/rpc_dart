// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';

/// Пример полной поддержки RpcContext во всех типах RPC методов:
/// - Унарные методы
/// - Server streaming
/// - Client streaming
/// - Bidirectional streaming
void main() async {
  RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);

  final logger = RpcLogger('ContextStreamsExample');
  logger.info('🚀 Запуск примера RPC Context для всех типов методов');

  // Создаем транспорты
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // Создаем серверный эндпоинт и регистрируем контракт
  final serverEndpoint = RpcResponderEndpoint(
    transport: serverTransport,
    debugLabel: 'Server',
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
  );

  final streamService = StreamServiceResponder();
  serverEndpoint.registerServiceContract(streamService);
  serverEndpoint.start();

  // Создаем клиентский эндпоинт
  final clientEndpoint = RpcCallerEndpoint(
    transport: clientTransport,
    debugLabel: 'Client',
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
  );

  final client = StreamServiceCaller(clientEndpoint);

  try {
    // Базовый контекст с аутентификацией и трассировкой
    final baseContext = RpcContextUtils.withBearerToken(
            'super-secret-token-123')
        .withAdditionalHeaders({
          'user-id': 'user-456',
          'session-id': 'session-${DateTime.now().millisecondsSinceEpoch}',
        })
        .withTraceId('example-trace-${DateTime.now().millisecondsSinceEpoch}')
        .withTimeout(Duration(seconds: 30));

    logger.info('📋 Базовый контекст создан:');
    logger.info('  - Trace ID: ${baseContext.traceId}');
    logger.info('  - User ID: ${baseContext.getHeader('user-id')}');
    logger.info('  - Session: ${baseContext.getHeader('session-id')}');

    // 1. Демонстрация унарного метода с контекстом
    logger.info('\n=== 1. Унарный метод с контекстом ===');
    final unaryResult = await client.processData(
      'Данные для обработки'.rpc,
      context: baseContext,
    );
    logger.info('✅ Унарный результат: $unaryResult');

    // 2. Демонстрация server streaming с контекстом
    logger.info('\n=== 2. Server streaming с контекстом ===');
    final serverStreamContext = baseContext.withValue('stream-type', 'server');

    await for (final chunk in client.generateData(
      'Генерируй данные'.rpc,
      context: serverStreamContext,
    )) {
      logger.info('📥 Получен chunk: $chunk');
    }

    // 3. Демонстрация client streaming с контекстом
    logger.info('\n=== 3. Client streaming с контекстом ===');
    final clientStreamContext = baseContext.withValue('stream-type', 'client');

    final clientDataStream = Stream.fromIterable([
      'Часть 1'.rpc,
      'Часть 2'.rpc,
      'Часть 3'.rpc,
    ]);

    final clientStreamResult = await client.aggregateData(
      clientDataStream,
      context: clientStreamContext,
    );
    logger.info('✅ Client stream результат: $clientStreamResult');

    // 4. Демонстрация bidirectional streaming с контекстом
    logger.info('\n=== 4. Bidirectional streaming с контекстом ===');
    final biStreamContext = baseContext
        .withValue('stream-type', 'bidirectional')
        .withAdditionalHeaders({'streaming-mode': 'echo'});

    final biDataController = StreamController<RpcString>();

    // Запускаем bidirectional stream
    final biResponseStream = client.processStream(
      biDataController.stream,
      context: biStreamContext,
    );

    // Подписываемся на ответы
    final biSubscription = biResponseStream.listen((response) {
      logger.info('🔄 Bidirectional ответ: $response');
    });

    // Отправляем данные
    biDataController.add('Сообщение 1'.rpc);
    await Future.delayed(Duration(milliseconds: 100));
    biDataController.add('Сообщение 2'.rpc);
    await Future.delayed(Duration(milliseconds: 100));
    biDataController.add('Сообщение 3'.rpc);

    await biDataController.close();
    await Future.delayed(Duration(milliseconds: 500)); // Ждем обработки

    await biSubscription.cancel();

    // 5. Демонстрация отмены операции через контекст
    logger.info('\n=== 5. Демонстрация отмены через контекст ===');
    final cancellationToken = CancellationToken();
    final cancellableContext = baseContext
        .withCancellation(cancellationToken)
        .withValue('operation', 'cancellable');

    // Запускаем долгую операцию
    final longOperation = client.longRunningOperation(
      'Долгая операция'.rpc,
      context: cancellableContext,
    );

    // Отменяем через 500мс
    Timer(Duration(milliseconds: 500), () {
      logger.info('⏹️ Отменяем операцию');
      cancellationToken.cancel('Операция отменена пользователем');
    });

    try {
      await longOperation;
      logger.warning('⚠️ Операция не была отменена');
    } catch (e) {
      logger.info('✅ Операция корректно отменена: $e');
    }
  } catch (e, stackTrace) {
    logger.error('❌ Ошибка при выполнении примера',
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

abstract interface class IStreamServiceContract implements IRpcContract {
  Future<RpcString> processData(RpcString data);
  Stream<RpcString> generateData(RpcString request);
  Future<RpcString> aggregateData(Stream<RpcString> dataStream);
  Stream<RpcString> processStream(Stream<RpcString> dataStream);
  Future<RpcString> longRunningOperation(RpcString data);
}

final class StreamServiceResponder extends RpcResponderContract
    implements IStreamServiceContract {
  StreamServiceResponder() : super('StreamService');

  @override
  void setup() {
    // Унарный метод
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ProcessData',
      handler: processData,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Обрабатывает данные с контекстом',
    );

    // Server streaming
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'GenerateData',
      handler: generateData,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Генерирует поток данных с контекстом',
    );

    // Client streaming
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'AggregateData',
      handler: aggregateData,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Агрегирует поток данных с контекстом',
    );

    // Bidirectional streaming
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'ProcessStream',
      handler: processStream,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Обрабатывает двунаправленный поток с контекстом',
    );

    // Долгая операция для демонстрации отмены
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'LongRunningOperation',
      handler: longRunningOperation,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Долгая операция для демонстрации отмены',
    );
  }

  // Реализуем интерфейсные методы
  @override
  Future<RpcString> processData(
    RpcString data, {
    RpcContext? context,
  }) async {
    final logger = RpcLogger('ProcessData');
    logger.info('🔧 Обработка данных: ${data.value}');
    logger.info('🔍 Context: $context');

    final userId = context?.getHeader('user-id');
    final traceId = context?.traceId;

    await Future.delayed(Duration(milliseconds: 100));

    return 'Обработано: ${data.value} [user: $userId, trace: $traceId]'.rpc;
  }

  @override
  Stream<RpcString> generateData(
    RpcString request, {
    RpcContext? context,
  }) async* {
    final logger = RpcLogger('GenerateData');
    logger.info('📊 Генерация данных для: ${request.value}');
    logger.info('🔍 Context: $context');

    final streamType = context?.getValue<String>('stream-type');
    final userId = context?.getHeader('user-id');

    for (int i = 1; i <= 3; i++) {
      // Проверяем отмену перед каждой итерацией
      context?.cancellationToken?.throwIfCancelled();

      await Future.delayed(Duration(milliseconds: 200));
      yield 'Данные #$i [$streamType] [user: $userId]'.rpc;
    }

    logger.info('✅ Генерация данных завершена');
  }

  @override
  Future<RpcString> aggregateData(
    Stream<RpcString> dataStream, {
    RpcContext? context,
  }) async {
    final logger = RpcLogger('AggregateData');
    logger.info('📥 Агрегация потока данных');
    logger.info('🔍 Context: $context');

    final streamType = context?.getValue<String>('stream-type');
    final userId = context?.getHeader('user-id');
    final items = <String>[];

    await for (final item in dataStream) {
      // Проверяем отмену при получении каждого элемента
      context?.cancellationToken?.throwIfCancelled();

      logger.info('📥 Получен item: ${item.value}');
      items.add(item.value);
    }

    final result =
        'Агрегированы ${items.length} элементов: ${items.join(", ")} [$streamType] [user: $userId]';
    logger.info('✅ Агрегация завершена: $result');

    return result.rpc;
  }

  @override
  Stream<RpcString> processStream(Stream<RpcString> dataStream,
      {RpcContext? context}) async* {
    final logger = RpcLogger('ProcessStream');
    logger.info('🔄 Обработка двунаправленного потока');
    logger.info('🔍 Context: $context');

    final streamType = context?.getValue<String>('stream-type');
    final mode = context?.getHeader('streaming-mode') ?? 'echo';
    final userId = context?.getHeader('user-id');

    await for (final item in dataStream) {
      // Проверяем отмену
      context?.cancellationToken?.throwIfCancelled();

      logger.info('🔄 Обрабатываем: ${item.value}');

      await Future.delayed(Duration(milliseconds: 50));

      yield '[$mode] ${item.value} [$streamType] [user: $userId]'.rpc;
    }

    logger.info('✅ Обработка потока завершена');
  }

  @override
  Future<RpcString> longRunningOperation(RpcString data,
      {RpcContext? context}) async {
    final logger = RpcLogger('LongRunning');
    logger.info('⏳ Запуск долгой операции: ${data.value}');
    logger.info('🔍 Context: $context');

    final operation = context?.getValue<String>('operation');

    for (int i = 0; i < 100; i++) {
      // Проверяем отмену каждые 100мс
      context?.cancellationToken?.throwIfCancelled();

      await Future.delayed(Duration(milliseconds: 100));

      if (i % 20 == 0) {
        logger.debug('📊 Прогресс операции $operation: $i%');
      }
    }

    return 'Долгая операция [$operation] завершена: ${data.value}'.rpc;
  }
}

//
// КЛИЕНТСКИЙ КОНТРАКТ
//

final class StreamServiceCaller extends RpcCallerContract
    implements IStreamServiceContract {
  StreamServiceCaller(RpcCallerEndpoint endpoint)
      : super('StreamService', endpoint);

  @override
  Future<RpcString> processData(RpcString data, {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'ProcessData',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: data,
      context: context,
    );
  }

  @override
  Stream<RpcString> generateData(RpcString request, {RpcContext? context}) {
    return callServerStream<RpcString, RpcString>(
      methodName: 'GenerateData',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: request,
      context: context,
    );
  }

  @override
  Future<RpcString> aggregateData(Stream<RpcString> dataStream,
      {RpcContext? context}) {
    return callClientStream<RpcString, RpcString>(
      methodName: 'AggregateData',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      requests: dataStream,
      context: context,
    );
  }

  @override
  Stream<RpcString> processStream(Stream<RpcString> dataStream,
      {RpcContext? context}) {
    return callBidirectionalStream<RpcString, RpcString>(
      methodName: 'ProcessStream',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      requests: dataStream,
      context: context,
    );
  }

  @override
  Future<RpcString> longRunningOperation(RpcString data,
      {RpcContext? context}) {
    return callUnary<RpcString, RpcString>(
      methodName: 'LongRunningOperation',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: data,
      context: context,
    );
  }
}
