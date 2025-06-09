// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';

/// Пример использования Client Stream RPC
///
/// Демонстрирует, как клиент может отправлять поток данных серверу,
/// а сервер обрабатывает их и возвращает единственный результат.
void main() async {
  print('=== Пример Client Stream RPC ===\n');

  // Создаем пару InMemoryTransport для тестирования
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // Создаем серверный эндпоинт
  final serverEndpoint = RpcResponderEndpoint(
    transport: serverTransport,
    debugLabel: 'Server',
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
  );

  // Создаем серверный контракт и регистрируем его
  final server = DataAggregatorResponder();
  serverEndpoint.registerServiceContract(server);

  // Создаем клиентский эндпоинт
  final clientEndpoint = RpcCallerEndpoint(
    transport: clientTransport,
    debugLabel: 'Client',
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.brightGreen),
  );

  final client = DataAggregatorCaller(clientEndpoint);

  try {
    // Создаем поток данных для отправки
    final dataChunks = Stream.fromIterable([
      DataChunk(id: 1, data: 'Первая порция данных', timestamp: DateTime.now()),
      DataChunk(id: 2, data: 'Вторая порция данных', timestamp: DateTime.now()),
      DataChunk(id: 3, data: 'Третья порция данных', timestamp: DateTime.now()),
      DataChunk(
          id: 4, data: 'Четвертая порция данных', timestamp: DateTime.now()),
    ]);

    print('КЛИЕНТ: Отправляем поток данных для агрегации...');

    // Создаем контекст с trace ID для отслеживания
    final context = RpcContext.empty()
        .withTraceId('client-stream-trace-123')
        .withValue('user-id', 'user-456');

    // Вызываем client stream метод через контракт
    final result = await client.aggregateData(dataChunks, context: context);

    print('КЛИЕНТ: Результат агрегации:');
    print('  - Обработано чанков: ${result.processedCount}');
    print('  - Общий размер данных: ${result.totalDataSize}');
    print('  - Статус: ${result.status}');
    print('  - Первый чанк: ${result.firstChunkData}');
    print('  - Последний чанк: ${result.lastChunkData}');
  } catch (e, stackTrace) {
    print('ОШИБКА: $e');
    print('StackTrace: $stackTrace');
  } finally {
    // Закрываем ресурсы
    await serverEndpoint.close();
    await clientEndpoint.close();
  }

  print('\n=== Пример завершен ===\n');
}

//
// СЕРВЕРНЫЙ КОНТРАКТ
//

final class DataAggregatorResponder extends RpcResponderContract {
  DataAggregatorResponder() : super('DataAggregatorService');

  @override
  void setup() {
    addClientStreamMethod<DataChunk, AggregationResult>(
      methodName: 'aggregateData',
      handler: _aggregateData,
      requestCodec: DataChunk.codec,
      responseCodec: AggregationResult.codec,
      description: 'Агрегирует поток данных в один результат',
    );
  }

  Future<AggregationResult> _aggregateData(
      RpcContext context, Stream<DataChunk> dataChunks) async {
    print('СЕРВЕР: Начинаем агрегацию данных...');
    print(
        'СЕРВЕР: Контекст - trace: ${context.traceId}, request: ${context.requestId}');

    final userId = context.getValue<String>('user-id');
    if (userId != null) {
      print('СЕРВЕР: Обрабатываем данные для пользователя: $userId');
    }

    final chunks = <DataChunk>[];
    int totalDataSize = 0;

    // Обрабатываем поток данных
    await for (final chunk in dataChunks) {
      // Проверяем не отменен ли запрос
      context.cancellationToken?.throwIfCancelled();

      print('СЕРВЕР: Получен чанк #${chunk.id}: "${chunk.data}"');
      chunks.add(chunk);
      totalDataSize += chunk.data.length;

      // Имитируем обработку
      await Future.delayed(Duration(milliseconds: 50));
    }

    print('СЕРВЕР: Агрегация завершена. Обработано ${chunks.length} чанков');

    // Формируем результат
    return AggregationResult(
      processedCount: chunks.length,
      totalDataSize: totalDataSize,
      status: chunks.isNotEmpty ? 'SUCCESS' : 'NO_DATA',
      firstChunkData: chunks.isNotEmpty ? chunks.first.data : null,
      lastChunkData: chunks.isNotEmpty ? chunks.last.data : null,
      aggregatedAt: DateTime.now(),
    );
  }
}

//
// КЛИЕНТСКИЙ КОНТРАКТ
//

final class DataAggregatorCaller extends RpcCallerContract {
  DataAggregatorCaller(RpcCallerEndpoint endpoint)
      : super('DataAggregatorService', endpoint);

  Future<AggregationResult> aggregateData(Stream<DataChunk> dataChunks,
      {RpcContext? context}) async {
    final clientStreamBuilder =
        endpoint.clientStream<DataChunk, AggregationResult>(
      serviceName: serviceName,
      methodName: 'aggregateData',
      requestCodec: DataChunk.codec,
      responseCodec: AggregationResult.codec,
      requests: dataChunks,
    );

    return await clientStreamBuilder();
  }
}

//
// МОДЕЛИ ДАННЫХ
//

class DataChunk implements IRpcSerializable {
  final int id;
  final String data;
  final DateTime timestamp;

  DataChunk({
    required this.id,
    required this.data,
    required this.timestamp,
  });

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'data': data,
        'timestamp': timestamp.toIso8601String(),
      };

  static DataChunk fromJson(Map<String, dynamic> json) => DataChunk(
        id: json['id'],
        data: json['data'],
        timestamp: DateTime.parse(json['timestamp']),
      );

  static RpcCodec<DataChunk> get codec => RpcCodec(DataChunk.fromJson);
}

class AggregationResult implements IRpcSerializable {
  final int processedCount;
  final int totalDataSize;
  final String status;
  final String? firstChunkData;
  final String? lastChunkData;
  final DateTime aggregatedAt;

  AggregationResult({
    required this.processedCount,
    required this.totalDataSize,
    required this.status,
    this.firstChunkData,
    this.lastChunkData,
    required this.aggregatedAt,
  });

  @override
  Map<String, dynamic> toJson() => {
        'processedCount': processedCount,
        'totalDataSize': totalDataSize,
        'status': status,
        'firstChunkData': firstChunkData,
        'lastChunkData': lastChunkData,
        'aggregatedAt': aggregatedAt.toIso8601String(),
      };

  static AggregationResult fromJson(Map<String, dynamic> json) =>
      AggregationResult(
        processedCount: json['processedCount'],
        totalDataSize: json['totalDataSize'],
        status: json['status'],
        firstChunkData: json['firstChunkData'],
        lastChunkData: json['lastChunkData'],
        aggregatedAt: DateTime.parse(json['aggregatedAt']),
      );

  static RpcCodec<AggregationResult> get codec =>
      RpcCodec(AggregationResult.fromJson);
}
