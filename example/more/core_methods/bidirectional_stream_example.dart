// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import 'package:rpc_dart/rpc_dart.dart';

void main() async {
  await BidirectionalStreamExample.run();
}

/// Пример использования двунаправленного стриминга (обмен сообщениями в обе стороны)
///
/// Демонстрирует, как клиент и сервер могут обмениваться сообщениями в реальном времени
class BidirectionalStreamExample {
  /// Запускает демонстрацию двунаправленного стриминга
  static Future<void> run() async {
    RpcLoggerSettings.setDefaultMinLogLevel(RpcLoggerLevel.debug);

    print(
        '\n=== Пример двунаправленного стриминга (N запросов <-> N ответов) ===\n');

    // Создаем пару соединенных транспортов для клиента и сервера
    final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

    // Создаем сериализаторы для строк
    final stringSerializer = RpcCodec(RpcString.fromJson);

    // Инициализируем серверную часть
    final server = BidirectionalStreamResponder<RpcString, RpcString>(
      id: 1,
      transport: serverTransport,
      serviceName: 'ChatService',
      methodName: 'Connect',
      requestCodec: stringSerializer,
      responseCodec: stringSerializer,
      logger: RpcLogger(
        'BidirectionalStreamExample',
        colors: RpcLoggerColors.singleColor(AnsiColor.brightYellow),
      ),
    );

    // ВАЖНО: Привязываем сервер к потоку сообщений для streamId = 1
    server.bindToMessageStream(
      serverTransport.incomingMessages.where((msg) => msg.streamId == 1),
    );

    // Настраиваем обработку запросов на сервере
    final serverSubscription = server.requests.listen((request) {
      print('СЕРВЕР: Получен запрос: "$request"');

      // Эхо-обработчик с некоторой логикой
      switch (request.value) {
        case 'ping':
          print('СЕРВЕР: Отправляем pong');
          server.send('pong'.rpc);
          break;
        case 'время':
          final timeResponse = 'Текущее время: ${DateTime.now()}';
          print('СЕРВЕР: Отправляем: "$timeResponse"');
          server.send(timeResponse.rpc);
          break;
        case 'случайное число':
          final random = (DateTime.now().millisecondsSinceEpoch % 100) + 1;
          final randomResponse = 'Случайное число от 1 до 100: $random';
          print('СЕРВЕР: Отправляем: "$randomResponse"');
          server.send(randomResponse.rpc);
          break;
        case 'завершить':
          final goodbyeMessage = 'Сервер завершает работу...';
          print('СЕРВЕР: Отправляем: "$goodbyeMessage"');
          server.send(goodbyeMessage.rpc);
          // Завершаем отправку с успешным статусом
          print('СЕРВЕР: Завершаем двунаправленный поток');
          server.finishReceiving();
          break;
        default:
          final echoResponse = 'Эхо: $request';
          print('СЕРВЕР: Отправляем: "$echoResponse"');
          server.send(echoResponse.rpc);
      }
    });

    // Инициализируем клиентскую часть
    final client = BidirectionalStreamCaller<RpcString, RpcString>(
      transport: clientTransport,
      serviceName: 'ChatService',
      methodName: 'Connect',
      requestCodec: stringSerializer,
      responseCodec: stringSerializer,
      logger: RpcLogger(
        'BidirectionalStreamExample',
        colors: RpcLoggerColors.singleColor(AnsiColor.brightBlue),
      ),
    );

    // Подписываемся на ответы сервера
    final clientSubscription = client.responses.listen((message) {
      if (!message.isMetadataOnly) {
        print('КЛИЕНТ: Получен ответ: "${message.payload}"');
      } else if (message.metadata != null) {
        final statusCode =
            message.metadata!.getHeaderValue(RpcConstants.GRPC_STATUS_HEADER);

        if (statusCode != null && message.isEndOfStream) {
          print('КЛИЕНТ: Соединение завершено со статусом: $statusCode');
        }
      }
    });

    // Отправляем несколько запросов с небольшой задержкой
    final requests = [
      'ping',
      'время',
      'случайное число',
      'привет, мир!',
      'завершить'
    ];

    for (final request in requests) {
      print('КЛИЕНТ: Отправляем запрос: "$request"');
      client.send(request.rpc);
      await Future.delayed(Duration(milliseconds: 100));
    }

    // Завершаем отправку запросов с клиента
    print('КЛИЕНТ: Завершаем отправку запросов');
    client.finishSending();

    // Ждем завершения обработки всех сообщений
    print('КЛИЕНТ: Ждем завершения обработки...');
    await Future.delayed(Duration(milliseconds: 500));

    // Закрываем подписки и освобождаем ресурсы
    await clientSubscription.cancel();
    await serverSubscription.cancel();
    await client.close();
    await server.close();

    print('\n=== Пример двунаправленного стриминга завершен ===\n');
  }
}
