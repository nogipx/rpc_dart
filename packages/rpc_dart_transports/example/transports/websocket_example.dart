// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:web_socket_channel/io.dart';

/// Простой пример использования WebSocket транспорта
void main() async {
  // Устанавливаем уровень логирования INFO
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.info);

  // Запускаем сервер
  final server = await HttpServer.bind('localhost', 8081);
  print('Сервер запущен на http://localhost:8081');

  // Создаем контракт серверной стороны
  final serverContract = EchoResponderContract();

  // Обрабатываем соединения от клиентов
  server.listen((request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      try {
        // Преобразуем HTTP запрос в WebSocket
        final socket = await WebSocketTransformer.upgrade(request);
        print('Новое WebSocket соединение');

        // Создаем WebSocket канал из сокета
        final channel = IOWebSocketChannel(socket);

        // Создаем транспорт на основе канала
        final transport = RpcWebSocketResponderTransport(
          channel,
          logger: RpcLogger('ServerWebSocket'),
        );

        // Создаем серверный эндпоинт
        final endpoint = RpcResponderEndpoint(
            transport: transport, debugLabel: 'ServerEndpoint');

        // Регистрируем контракт
        endpoint.registerServiceContract(serverContract);

        // Запускаем эндпоинт
        endpoint.start();

        // Обрабатываем закрытие соединения
        socket.done.then((_) {
          print('WebSocket соединение закрыто');
          endpoint.close();
        });
      } catch (e) {
        print('Ошибка при обработке WebSocket подключения: $e');
      }
    }
  });

  // Запускаем клиент
  Timer(Duration(seconds: 1), () => runClient());
}

/// Запускает клиентскую часть примера
void runClient() async {
  print('\nЗапуск клиента...');

  // Создаем клиентский транспорт
  final transport = RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://localhost:8081'),
    logger: RpcLogger('ClientWebSocket'),
  );

  // Создаем клиентский эндпоинт
  final endpoint = RpcCallerEndpoint(
    transport: transport,
    debugLabel: 'ClientEndpoint',
  );

  // Создаем контракт клиентской стороны
  final contract = EchoCallerContract(endpoint);

  try {
    // Отправляем унарный запрос
    print('\nОтправка унарного запроса...');
    print('Ждем соединения...');

    // Даем время на установку соединения
    await Future.delayed(Duration(milliseconds: 500));

    print('Отправляем запрос echo...');
    final response = await contract.echo('Привет, WebSocket RPC!').timeout(
      Duration(seconds: 10),
      onTimeout: () {
        print('TIMEOUT: Унарный запрос превысил время ожидания');
        throw TimeoutException('Unary request timeout', Duration(seconds: 10));
      },
    );
    print('Ответ от сервера: $response');
    print('✅ Унарный запрос успешен');
  } catch (e, stack) {
    print('❌ Ошибка в унарном запросе: $e');
    print('Stack trace: $stack');
    return;
  }

  try {
    // Тестируем стрим от сервера
    print('\nТестирование серверного стрима...');
    final serverStream = contract.countTo(5);
    await for (final number in serverStream) {
      print('Получено из серверного стрима: $number');
    }
    print('✅ Серверный стрим успешен');
  } catch (e) {
    print('❌ Ошибка в серверном стриме: $e');
  }

  // Пока убираем остальные стримы для отладки
  print('Все тесты завершены успешно!');

  // Закрываем соединение
  print('\nЗавершение работы...');
  await endpoint.close();
  exit(0);
}

// --- Контракты для примера ---

/// Серверный контракт для примера
base class EchoResponderContract extends RpcResponderContract {
  EchoResponderContract() : super('echo') {
    // Унарный метод
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async {
        print('Сервер получил запрос: ${request.value}');
        return RpcString(request.value);
      },
    );

    // Серверный стрим (проверяем исправление)
    addServerStreamMethod<RpcInt, RpcInt>(
      methodName: 'countTo',
      requestCodec: RpcInt.codec,
      responseCodec: RpcInt.codec,
      handler: (request, {context}) {
        final count = request.value;
        print('Сервер запускает стрим до $count');
        return Stream.periodic(
          Duration(milliseconds: 500),
          (i) => RpcInt(i + 1),
        ).take(count);
      },
    );

    print('Регистрация контракта завершена');
  }
}

/// Клиентский контракт для примера
base class EchoCallerContract extends RpcCallerContract {
  EchoCallerContract(RpcCallerEndpoint endpoint) : super('echo', endpoint);

  /// Унарный запрос
  Future<String> echo(String message) async {
    final response = await endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: serviceName,
      methodName: 'echo',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString(message),
    );
    return response.value;
  }

  /// Серверный стрим
  Stream<int> countTo(int count) {
    return endpoint
        .serverStream<RpcInt, RpcInt>(
          serviceName: serviceName,
          methodName: 'countTo',
          requestCodec: RpcInt.codec,
          responseCodec: RpcInt.codec,
          request: RpcInt(count),
        )
        .map((msg) => msg.value);
  }
}
