// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/diagnostics.dart';
import 'client_streaming_contract.dart';
import 'client_streaming_models.dart';

const String _source = 'ClientStreamingExample';

/// Главная функция примера клиентского стриминга
Future<void> runClientStreamingExample({bool debug = false}) async {
  printHeader('Пример клиентского стриминга RPC');

  // Создаем два локальных транспорта для демонстрации
  final serverTransport = MemoryTransport('server');
  final clientTransport = MemoryTransport('client');

  // Соединяем транспорты между собой
  serverTransport.connect(clientTransport);
  clientTransport.connect(serverTransport);
  RpcLog.info(message: 'Транспорты соединены', source: _source);

  try {
    // Создаем эндпоинты для сервера и клиента
    final serverEndpoint = RpcEndpoint(
      transport: serverTransport,
      debugLabel: 'server',
    );

    final clientEndpoint = RpcEndpoint(
      transport: clientTransport,
      debugLabel: 'client',
    );

    // Добавляем middleware в зависимости от режима отладки
    if (debug) {
      serverEndpoint.addMiddleware(DebugMiddleware(id: "server"));
      clientEndpoint.addMiddleware(DebugMiddleware(id: "client"));
    } else {
      serverEndpoint.addMiddleware(LoggingMiddleware(id: "server"));
      clientEndpoint.addMiddleware(LoggingMiddleware(id: "client"));
    }

    RpcLog.info(message: 'Эндпоинты созданы', source: _source);

    // Создаем и регистрируем серверную часть
    final serverService = ServerStreamService();
    serverEndpoint.registerServiceContract(serverService);
    RpcLog.info(message: 'Серверный сервис зарегистрирован', source: _source);

    // Создаем клиентскую часть
    final clientService = ClientStreamService(clientEndpoint);
    clientEndpoint.registerServiceContract(clientService);
    RpcLog.info(message: 'Клиентский сервис зарегистрирован', source: _source);

    // Запускаем демонстрацию
    await demonstrateFileUpload(clientService);
  } catch (e, stack) {
    RpcLog.error(
      message: 'Произошла ошибка',
      source: _source,
      error: {'error': e.toString()},
      stackTrace: stack.toString(),
    );
    RpcLog.info(message: 'Закрываем эндпоинты...', source: _source);
  } finally {
    await serverTransport.close();
    RpcLog.info(message: 'Эндпоинты закрыты', source: _source);
  }

  printHeader('Пример завершен');
}

/// Демонстрирует процесс загрузки файла частями
Future<void> demonstrateFileUpload(ClientStreamService clientService) async {
  printHeader('Демонстрация загрузки файла частями');

  // Создаем тестовые данные (имитация большого файла)
  RpcLog.info(message: '📁 Подготовка тестовых данных...', source: _source);
  final fileData = List.generate(
    10,
    (i) => DataBlock(
      index: i,
      data: _generateData(100000, i).toList(), // 100 KB на блок
      metadata:
          'filename=test_file.dat;mime=application/octet-stream;chunkSize=100000',
    ),
  );

  int totalSize = 0;
  for (final block in fileData) {
    totalSize += block.data.length;
  }

  try {
    // Открываем поток для отправки данных
    RpcLog.info(
      message: '🔄 Открытие канала для отправки файла...',
      source: _source,
    );
    final uploadStream = clientService.processDataBlocks();

    // Отправляем блоки файла
    RpcLog.info(message: '📤 Отправка файла частями...', source: _source);

    for (final block in fileData) {
      // Отправляем каждый блок в потоке
      uploadStream.send(block);
      RpcLog.info(
        message: '📦 Отправлен блок #${block.index}: ${block.data.length} байт',
        source: _source,
      );
    }

    // Завершаем отправку (это сигнализирует серверу, что все данные отправлены)
    RpcLog.info(
      message: '✅ Завершение отправки файла ($totalSize байт)',
      source: _source,
    );
    await uploadStream.finishSending();

    // Закрываем поток клиентской части и ждем ответ
    RpcLog.info(
      message: '🔒 Канал отправки закрыт, ожидаем ответ сервера...',
      source: _source,
    );
    final result = await uploadStream.getResponse();

    // Получаем и выводим результат обработки
    if (result.blockCount > 0) {
      printHeader('Результат загрузки и обработки файла');

      RpcLog.info(
        message: '  • Обработано блоков: ${result.blockCount}',
        source: _source,
      );
      RpcLog.info(
        message: '  • Общий размер: ${result.totalSize} байт',
        source: _source,
      );
      RpcLog.info(message: '  • Файл: ${result.metadata}', source: _source);
      RpcLog.info(
        message: '  • Время обработки: ${result.processingTime}',
        source: _source,
      );

      RpcLog.info(
        message: '✅ Файл успешно загружен и обработан!',
        source: _source,
      );
    }
  } catch (e) {
    RpcLog.error(
      message: '❌ Ошибка при отправке файла',
      source: _source,
      error: {'error': e.toString()},
    );
  }
}

/// Печатает заголовок раздела
void printHeader(String title) {
  RpcLog.info(message: '-------------------------', source: _source);
  RpcLog.info(message: ' $title', source: _source);
  RpcLog.info(message: '-------------------------', source: _source);
}

/// Генерирует тестовые данные указанного размера
Uint8List _generateData(int size, int seed) {
  final data = Uint8List(size);
  for (var i = 0; i < size; i++) {
    data[i] = (i + seed) % 256;
  }
  return data;
}

/// Основная функция
Future<void> main({bool debug = false}) async {
  await runClientStreamingExample(debug: debug);
}
