// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await ServerStreamingExample.run();
}

/// Пример использования серверного стриминга (один запрос, много ответов)
/// с использованием новых контрактов и RpcContext
class ServerStreamingExample {
  static Future<void> run() async {
    RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.debug);
    print('\n=== Пример серверного стриминга с контрактами ===\n');

    // Создаем транспорты
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

    // Создаем серверный эндпоинт и регистрируем контракт
    final serverEndpoint = RpcResponderEndpoint(
      transport: serverTransport,
      debugLabel: 'Server',
      loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
    );

    final service = DataStreamServiceResponder();
    serverEndpoint.registerServiceContract(service);
    serverEndpoint.start();

    // Создаем клиентский эндпоинт
    final clientEndpoint = RpcCallerEndpoint(
      transport: clientTransport,
      debugLabel: 'Client',
      loggerColors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
    );

    final client = DataStreamServiceCaller(clientEndpoint);

    try {
      // Пример 1: Простой server stream
      print('\n--- Пример 1: Простой server stream ---');

      final context1 = RpcContext.empty()
          .withTraceId('server-stream-trace-123')
          .withValue('stream-type', 'simple');

      await for (final response
          in client.getServerStream('Дай мне данные'.rpc, context: context1)) {
        print('КЛИЕНТ: Получен ответ: "$response"');
      }

      // Пример 2: Server stream с числовой последовательностью
      print('\n--- Пример 2: Server stream с числами ---');

      final context2 = RpcContext.empty()
          .withTraceId('numbers-stream-trace-456')
          .withAdditionalHeaders({'count': '10', 'delay': '100'});

      await for (final number
          in client.getNumberStream(5.rpc, context: context2)) {
        print('КЛИЕНТ: Получено число: $number');
      }

      // Пример 3: Server stream с отменой
      print('\n--- Пример 3: Server stream с отменой ---');

      final cancellationToken = RpcCancellationToken();
      final cancelContext = RpcContext.withCancellation(cancellationToken)
          .withValue('stream-type', 'long-running');

      // Отменяем через 200мс
      Future.delayed(Duration(milliseconds: 200), () {
        print('КЛИЕНТ: Отменяем stream');
        cancellationToken.cancel('User cancelled');
      });

      try {
        await for (final response in client.getLongRunningStream(
            'Долгий stream'.rpc,
            context: cancelContext)) {
          print('КЛИЕНТ: Получен ответ: "$response"');
        }
      } catch (e) {
        print('КЛИЕНТ: Stream отменен: $e');
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

abstract interface class IDataStreamServiceContract implements IRpcContract {
  Stream<RpcString> getServerStream(RpcString request);
  Stream<RpcInt> getNumberStream(RpcInt count);
  Stream<RpcString> getLongRunningStream(RpcString request);
}

final class DataStreamServiceResponder extends RpcResponderContract
    implements IDataStreamServiceContract {
  DataStreamServiceResponder() : super('DataStreamService');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'GetServerStream',
      handler: getServerStream,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Отправляет поток строк в ответ на один запрос',
    );

    addServerStreamMethod<RpcInt, RpcInt>(
      methodName: 'GetNumberStream',
      handler: getNumberStream,
      requestCodec: RpcInt.codec,
      responseCodec: RpcInt.codec,
      description: 'Отправляет поток чисел',
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'GetLongRunningStream',
      handler: getLongRunningStream,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Долгий поток для тестирования отмены',
    );
  }

  @override
  Stream<RpcString> getServerStream(RpcString request,
      {RpcContext? context}) async* {
    final logger = RpcLogger('GetServerStream');
    logger.info('🔧 Получен запрос: ${request.value}');
    logger.info('🔍 Context: $context');

    final streamType = context?.getValue<String>('stream-type');
    logger.info('📡 Stream type: $streamType');

    // Отправляем несколько ответов с задержкой
    for (int i = 1; i <= 5; i++) {
      context?.cancellationToken?.throwIfCancelled();

      final response = 'Ответ #$i на запрос "${request.value}"';
      logger.internal('🎯 Отправляем: $response');
      yield response.rpc;

      await Future.delayed(Duration(milliseconds: 50));
    }

    logger.info('✅ Завершен поток ответов');
  }

  @override
  Stream<RpcInt> getNumberStream(RpcInt count, {RpcContext? context}) async* {
    final logger = RpcLogger('GetNumberStream');
    logger.info('🔧 Получен запрос на числа: ${count.value}');
    logger.info('🔍 Context: $context');

    final requestedCount = count.value;
    final countHeader = context?.getHeader('count');
    final delayHeader = context?.getHeader('delay');

    final actualCount =
        countHeader != null ? int.parse(countHeader) : requestedCount;
    final delay = delayHeader != null ? int.parse(delayHeader) : 50;

    logger.info('🔢 Отправляем $actualCount чисел с задержкой $delay мс');

    for (int i = 0; i < actualCount; i++) {
      context?.cancellationToken?.throwIfCancelled();

      logger.internal('🎯 Отправляем число: $i');
      yield i.rpc;

      await Future.delayed(Duration(milliseconds: delay));
    }

    logger.info('✅ Завершен поток чисел');
  }

  @override
  Stream<RpcString> getLongRunningStream(RpcString request,
      {RpcContext? context}) async* {
    final logger = RpcLogger('GetLongRunningStream');
    logger.info('🔧 Начинаем долгий поток: ${request.value}');
    logger.info('🔍 Context: $context');

    try {
      // Отправляем 20 сообщений с интервалом 100мс (2 секунды общее время)
      for (int i = 1; i <= 20; i++) {
        context?.cancellationToken?.throwIfCancelled();

        final response = 'Долгий ответ #$i для "${request.value}"';
        logger.internal('🎯 Отправляем: $response');
        yield response.rpc;

        await Future.delayed(Duration(milliseconds: 100));
      }

      logger.info('✅ Завершен долгий поток');
    } catch (e) {
      logger.warning('⚠️ Долгий поток отменен: $e');
      rethrow;
    }
  }
}

//
// КЛИЕНТСКИЙ КОНТРАКТ
//

final class DataStreamServiceCaller extends RpcCallerContract
    implements IDataStreamServiceContract {
  DataStreamServiceCaller(RpcCallerEndpoint endpoint)
      : super('DataStreamService', endpoint);

  @override
  Stream<RpcString> getServerStream(RpcString request, {RpcContext? context}) {
    return callServerStream<RpcString, RpcString>(
      methodName: 'GetServerStream',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: request,
      context: context,
    );
  }

  @override
  Stream<RpcInt> getNumberStream(RpcInt count, {RpcContext? context}) {
    return callServerStream<RpcInt, RpcInt>(
      methodName: 'GetNumberStream',
      requestCodec: RpcInt.codec,
      responseCodec: RpcInt.codec,
      request: count,
      context: context,
    );
  }

  @override
  Stream<RpcString> getLongRunningStream(RpcString request,
      {RpcContext? context}) {
    return callServerStream<RpcString, RpcString>(
      methodName: 'GetLongRunningStream',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: request,
      context: context,
    );
  }
}
