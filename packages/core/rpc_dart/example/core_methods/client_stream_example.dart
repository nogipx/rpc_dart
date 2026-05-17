// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
import 'package:rpc_dart/rpc_dart.dart';
void main() async {
  await ClientStreamingExample.run();
}
/// Пример использования клиентского стриминга (много запросов, один ответ)
///
/// Демонстрирует, как клиент отправляет поток запросов и получает один ответ
class ClientStreamingExample {
  /// Запускает демонстрацию клиентского стриминга
  static Future<void> run() async {
    // logging configured via LogController
    print('\n=== Пример клиентского стриминга (N запросов -> 1 ответ) ===\n');
    // Создаем пару соединенных транспортов для клиента и сервера
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
    // Создаем серверный эндпоинт
    final serverEndpoint = RpcResponderEndpoint(
      transport: serverTransport,
      debugLabel: 'ClientStreamServer',
      
    );
    // Создаем клиентский эндпоинт
    final clientEndpoint = RpcCallerEndpoint(
      transport: clientTransport,
      debugLabel: 'ClientStreamClient',
      
    );
    // Регистрируем серверный контракт
    final serverContract = DataAggregatorResponder();
    serverEndpoint.registerServiceContract(serverContract);
    serverEndpoint.start();
    // Создаем клиентский контракт
    final client = DataAggregatorCaller(clientEndpoint);
    try {
      // Пример 1: Базовая агрегация данных
      print('\n--- Пример 1: Агрегация текстовых сообщений ---');
      final context1 = RpcContextUtils.withTracing(
        traceId: 'client-stream-123',
      ).withValue('aggregation-type', 'text');
      final messages = [
        'Сообщение 1: Привет',
        'Сообщение 2: Как дела?',
        'Сообщение 3: Это тест',
        'Сообщение 4: Клиентского',
        'Сообщение 5: Стриминга!',
      ];
      print('КЛИЕНТ: Отправляем ${messages.length} сообщений');
      final messageStream = Stream.fromIterable(messages.map((m) => m.rpc))
          .asyncMap((message) async {
        print('КЛИЕНТ: → "${message.value}"');
        // Небольшая задержка между сообщениями
        await Future.delayed(Duration(milliseconds: 50));
        return message;
      });
      final result1 = await client.aggregateMessages(
        messageStream,
        context: context1,
      );
      print('КЛИЕНТ: Результат агрегации: "${result1.value}"');
      // Пример 2: Агрегация с аутентификацией
      print('\n--- Пример 2: Агрегация с аутентификацией ---');
      final authContext = RpcContextUtils.withBearerToken('aggregate-token-456')
          .withAdditionalHeaders({
        'client-version': '1.4.0',
        'aggregation-format': 'structured',
      }).withTraceId('auth-aggregate-456');
      final secureMessages = [
        'admin:status',
        'admin:reports',
        'admin:analytics',
        'admin:summary',
      ];
      final secureStream = Stream.fromIterable(secureMessages.map((m) => m.rpc))
          .asyncMap((message) async {
        print('КЛИЕНТ: → Защищенное сообщение: "${message.value}"');
        await Future.delayed(Duration(milliseconds: 30));
        return message;
      });
      final result2 = await client.aggregateMessages(
        secureStream,
        context: authContext,
      );
      print('КЛИЕНТ: Защищенный результат: "${result2.value}"');
      // Пример 3: Агрегация с отменой
      print('\n--- Пример 3: Агрегация с отменой ---');
      final cancellationToken = RpcCancellationToken();
      final cancelContext = RpcContext.withCancellation(
        cancellationToken,
      ).withValue('batch-size', 100).withTraceId('cancel-aggregate-789');
      // Отменяем через 150мс
      Future.delayed(Duration(milliseconds: 150), () {
        print('КЛИЕНТ: Отменяем агрегацию');
        cancellationToken.cancel('User cancelled operation');
      });
      final longMessages = Stream.periodic(
        Duration(milliseconds: 50),
        (i) => 'Batch item #$i'.rpc,
      ).take(10);
      try {
        final result3 = await client.aggregateMessages(
          longMessages,
          context: cancelContext,
        );
        print('КЛИЕНТ: Результат отменённой агрегации: "${result3.value}"');
      } catch (e) {
        print('КЛИЕНТ: Агрегация отменена: $e');
      }
      // Пример 4: Агрегация файлов
      print('\n--- Пример 4: Агрегация файлов ---');
      final fileContext = RpcContext.withHeaders({
        'operation': 'file-processing',
        'format': 'batch',
      }).withTimeout(Duration(seconds: 5)).withTraceId('file-aggregate-012');
      final fileMessages = [
        'file:document1.pdf',
        'file:image2.jpg',
        'file:data3.json',
        'file:report4.xlsx',
      ];
      final fileStream = Stream.fromIterable(fileMessages.map((f) => f.rpc));
      final result4 = await client.aggregateMessages(
        fileStream,
        context: fileContext,
      );
      print('КЛИЕНТ: Результат обработки файлов: "${result4.value}"');
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
abstract interface class IDataAggregatorContract implements IRpcContract {
  Future<RpcString> aggregateMessages(Stream<RpcString> messages);
}
final class DataAggregatorResponder extends RpcResponderContract
    implements IDataAggregatorContract {
  DataAggregatorResponder() : super('DataAggregatorService');
  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'AggregateMessages',
      handler: aggregateMessages,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      description: 'Агрегирует поток сообщений и возвращает сводку',
    );
  }
  @override
  Future<RpcString> aggregateMessages(
    Stream<RpcString> messages, {
    RpcContext? context,
  }) async {
    final logger = LogScope.noop;
    logger.info('🔧 Начинаем агрегацию сообщений');
    logger.info('🔍 Context: $context');
    final aggregationType = context?.getValue<String>('aggregation-type');
    final batchSize = context?.getValue<int>('batch-size');
    final format = context?.getHeader('aggregation-format');
    final operation = context?.getHeader('operation');
    final authToken = context?.getHeader('authorization');
    logger.info(
      '📊 Type: $aggregationType, Batch: $batchSize, Format: $format',
    );
    final receivedMessages = <String>[];
    int count = 0;
    try {
      await for (final message in messages) {
        context?.cancellationToken?.throwIfCancelled();
        count++;
        receivedMessages.add(message.value);
        logger.internal('📨 Получено сообщение #$count: "${message.value}"');
        // Имитируем обработку
        await Future.delayed(Duration(milliseconds: 10));
        // Проверяем лимит для batch обработки
        if (batchSize != null && count >= batchSize) {
          logger.info('📊 Достигнут лимит batch: $batchSize');
          break;
        }
      }
      logger.info('✅ Агрегация завершена, обработано сообщений: $count');
      // Формируем результат в зависимости от контекста
      final String result;
      if (operation == 'file-processing') {
        result = _aggregateFiles(receivedMessages);
      } else if (authToken != null && authToken.startsWith('Bearer ')) {
        result = _aggregateSecureMessages(receivedMessages, format);
      } else {
        result = _aggregateRegularMessages(receivedMessages, aggregationType);
      }
      logger.internal('📤 Отправляем результат: "$result"');
      return result.rpc;
    } catch (e) {
      logger.warning('⚠️ Агрегация отменена: $e');
      final partialResult =
          'Частичная агрегация: обработано $count из ${receivedMessages.length} сообщений';
      return partialResult.rpc;
    }
  }
  String _aggregateRegularMessages(List<String> messages, String? type) {
    final totalChars = messages.fold<int>(0, (sum, msg) => sum + msg.length);
    return 'Агрегировано ${messages.length} сообщений ($totalChars символов)';
  }
  String _aggregateSecureMessages(List<String> messages, String? format) {
    final adminCommands = messages.where((m) => m.startsWith('admin:')).length;
    if (format == 'structured') {
      return 'Secure Report: {total: ${messages.length}, admin_commands: $adminCommands, timestamp: ${DateTime.now()}}';
    }
    return 'Обработано ${messages.length} защищенных сообщений ($adminCommands команд admin)';
  }
  String _aggregateFiles(List<String> messages) {
    final files = messages.where((m) => m.startsWith('file:')).length;
    final totalSize = messages.length * 1024; // Имитация размера
    return 'Обработано файлов: $files, общий размер: $totalSize KB';
  }
}
//
// КЛИЕНТСКИЙ КОНТРАКТ
//
final class DataAggregatorCaller extends RpcCallerContract
    implements IDataAggregatorContract {
  DataAggregatorCaller(RpcCallerEndpoint endpoint)
      : super('DataAggregatorService', endpoint);
  @override
  Future<RpcString> aggregateMessages(
    Stream<RpcString> messages, {
    RpcContext? context,
  }) {
    return callClientStream<RpcString, RpcString>(
      methodName: 'AggregateMessages',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      requests: messages,
      context: context,
    );
  }
}
