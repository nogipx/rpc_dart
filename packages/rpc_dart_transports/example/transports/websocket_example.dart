// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Пример: реальный WebSocket-сервер + клиент.
/// Серверная часть: shelf_web_socket -> Stream(WebSocketChannel) -> RpcWebSocketServer.
/// Клиент: WebSocketChannel.connect -> RpcWebSocketCallerTransport.
Future<void> main() async {
  // 1) Логирование
  RpcLogger.setDefaultMinLogLevel(RpcLoggerLevel.info);

  // 2) Контроллер входящих подключений для RpcWebSocketServer
  final incomingConnections = StreamController<WebSocketChannel>.broadcast();

  // 3) Контракты сервера
  final serverContract = EchoResponderContract();

  // 4) Поднимаем RpcWebSocketServer поверх входящего стрима каналов
  final rpcServer = RpcWebSocketServer.createWithContracts(
    connections: incomingConnections.stream,
    host: '0.0.0.0',
    port: 8081, // информативно (биндинг делает shelf)
    contracts: [serverContract],
    logger: RpcLogger('RPC-Server'),
  );
  await rpcServer.start();

  // 5) Настраиваем shelf WebSocket handler: каждое подключение отправляем серверу
  final wsHandler = webSocketHandler((WebSocketChannel ch, str) {
    print('[shelf] Новое WebSocket соединение ($str)');
    incomingConnections.add(ch);
  });

  // (опционально) логируем HTTP-запросы
  final handler = const Pipeline().addHandler(wsHandler);

  // 6) Реальный HTTP биндинг (без прямого импорта dart:io в этом файле)
  final shelfServer = await shelf_io.serve(handler, '127.0.0.1', 8081);
  print('✅ WebSocket сервер слушает ws://127.0.0.1:8081');

  // 7) Запускаем клиента
  await runClient();

  // 8) Грейсфул-шатдаун
  await rpcServer.stop();
  await incomingConnections.close();
  await shelfServer.close(force: true);
  print('👋 Завершено.');
}

/// Клиентский запуск: коннект к реальному ws:// и тест двух методов
Future<void> runClient() async {
  print('\n— Клиент: подключение к серверу...');

  final endpoint = RpcCallerEndpoint(
    transport: RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:8081'),
    ),
    debugLabel: 'ClientEndpoint',
  );

  final contract = EchoCallerContract(endpoint);

  try {
    print('— Клиент: унарный запрос');
    final response = await contract
        .echo('Привет, WebSocket RPC!')
        .timeout(const Duration(seconds: 10));
    print('Ответ от сервера: $response');
    print('✅ Унарный запрос успешен');
  } catch (e, st) {
    print('❌ Ошибка унарного запроса: $e');
    print(st);
    await endpoint.close();
    return;
  }

  try {
    print('\n— Клиент: серверный стрим');
    await for (final n in contract.countTo(5)) {
      print('Получено из стрима: $n');
    }
    print('✅ Стрим успешен');
  } catch (e, st) {
    print('❌ Ошибка стрима: $e');
    print(st);
  }

  print('\n— Клиент: закрытие соединения');
  await endpoint.close();
}

// --- Контракты для примера ---

/// Серверный контракт
base class EchoResponderContract extends RpcResponderContract {
  EchoResponderContract() : super('echo') {
    // Унарный метод
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      handler: (request, {context}) async {
        print('[server] echo: ${request.value}');
        return RpcString(request.value);
      },
    );

    // Серверный стрим
    addServerStreamMethod<RpcInt, RpcInt>(
      methodName: 'countTo',
      requestCodec: RpcInt.codec,
      responseCodec: RpcInt.codec,
      handler: (request, {context}) {
        final count = request.value;
        print('[server] stream countTo: $count');
        return Stream.periodic(
          const Duration(milliseconds: 400),
          (i) => RpcInt(i + 1),
        ).take(count);
      },
    );

    print('[server] Контракт зарегистрирован');
  }
}

/// Клиентский контракт
base class EchoCallerContract extends RpcCallerContract {
  EchoCallerContract(RpcCallerEndpoint endpoint) : super('echo', endpoint);

  Future<String> echo(String message) async {
    final resp = await endpoint.unaryRequest<RpcString, RpcString>(
      serviceName: serviceName,
      methodName: 'echo',
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
      request: RpcString(message),
    );
    return resp.value;
  }

  Stream<int> countTo(int count) {
    return endpoint
        .serverStream<RpcInt, RpcInt>(
          serviceName: serviceName,
          methodName: 'countTo',
          requestCodec: RpcInt.codec,
          responseCodec: RpcInt.codec,
          request: RpcInt(count),
        )
        .map((m) => m.value);
  }
}
