// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';

/// Пример использования Client Stream через контракты
///
/// Демонстрирует правильный способ создания Client Stream
/// методов с использованием RpcResponderContract и RpcCallerContract
void main() async {
  RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);

  print('\n=== Client Stream через контракты ===\n');

  // Создаем транспорты
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

  // Создаем серверный эндпоинт и регистрируем контракт
  final serverEndpoint = RpcResponderEndpoint(
    transport: serverTransport,
    debugLabel: 'Server',
    loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
  );

  final serverContract = DataAggregatorResponder();
  serverEndpoint.registerServiceContract(serverContract);
  serverEndpoint.start(); // Явно запускаем!

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

    // Вызываем client stream метод через контракт
    final result = await client.aggregateData(dataChunks);

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
// ИНТЕРФЕЙС КОНТРАКТА
//

abstract interface class IDataAggregatorContract implements IRpcContract {
  /// Client Stream метод: получает поток данных и возвращает агрегированный результат
  Future<AggregationResult> aggregateData(Stream<DataChunk> dataChunks);
}

//
// СЕРВЕРНЫЙ КОНТРАКТ
//

final class DataAggregatorResponder extends RpcResponderContract
    implements IDataAggregatorContract {
  DataAggregatorResponder() : super('DataAggregatorService');

  @override
  void setup() {
    addClientStreamMethod<DataChunk, AggregationResult>(
      methodName: 'aggregateData',
      handler: aggregateData,
      requestCodec: DataChunk.codec,
      responseCodec: AggregationResult.codec,
      description: 'Агрегирует поток данных в один результат',
    );
  }

  @override
  Future<AggregationResult> aggregateData(Stream<DataChunk> dataChunks) async {
    print('СЕРВЕР: Начинаем агрегацию данных...');

    final chunks = <DataChunk>[];
    int totalDataSize = 0;

    // Обрабатываем поток данных
    await for (final chunk in dataChunks) {
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

final class DataAggregatorCaller extends RpcCallerContract
    implements IDataAggregatorContract {
  DataAggregatorCaller(RpcCallerEndpoint endpoint)
      : super('DataAggregatorService', endpoint);

  @override
  Future<AggregationResult> aggregateData(Stream<DataChunk> dataChunks) async {
    // Используем clientStream метод эндпоинта
    final clientStreamBuilder =
        endpoint.clientStream<DataChunk, AggregationResult>(
      serviceName: serviceName,
      methodName: 'aggregateData',
      requestCodec: DataChunk.codec,
      responseCodec: AggregationResult.codec,
      requests: dataChunks,
    );

    // Выполняем запрос
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
